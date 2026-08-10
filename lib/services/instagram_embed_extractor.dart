import 'dart:convert';

class EmbedExtractionException implements Exception {
  EmbedExtractionException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ExtractedMediaItem {
  const ExtractedMediaItem({
    required this.type,
    required this.url,
    required this.ext,
    this.thumbnail,
    this.width,
    this.height,
  });

  final String type;
  final String url;
  final String ext;
  final String? thumbnail;
  final int? width;
  final int? height;

  bool get isVideo => type == 'video';
}

class ExtractedMedia {
  const ExtractedMedia({
    required this.title,
    required this.author,
    required this.items,
    this.thumbnail,
    this.duration,
    this.isReel = false,
    this.isCarousel = false,
  });

  final String title;
  final String author;
  final List<ExtractedMediaItem> items;
  final String? thumbnail;
  final double? duration;
  final bool isReel;
  final bool isCarousel;

  bool get isVideo => !isCarousel && items.isNotEmpty && items.every((i) => i.isVideo);
}

class InstagramEmbedExtractor {
  static ExtractedMedia parseHtml(String html) {
    final context = _parseContextJson(html);
    if (context == null) {
      throw EmbedExtractionException('Could not extract media from embed page.');
    }

    if (context.containsKey('shortcode_media') ||
        context['gql_data'] is Map<String, dynamic>) {
      return _parseLegacyMedia(context);
    }

    return _parseModernMedia(context);
  }

  static Map<String, dynamic>? _parseContextJson(String html) {
    final initMatch = RegExp(
      r'"init",\[\],\[(.*)\]\],\["NavigationMetrics',
    ).firstMatch(html);
    if (initMatch != null) {
      try {
        final init = jsonDecode(initMatch.group(1)!);
        if (init is Map<String, dynamic>) {
          final rawContext = init['contextJSON'];
          if (rawContext == null) {
            throw EmbedExtractionException('Embed page returned empty media data.');
          }
          if (rawContext is String) {
            final decoded = jsonDecode(rawContext);
            if (decoded is Map<String, dynamic>) return decoded;
          } else if (rawContext is Map<String, dynamic>) {
            return rawContext;
          }
        }
      } on EmbedExtractionException {
        rethrow;
      } catch (_) {
        // Fall through to regex fallback.
      }
    }

    final contextMatch = RegExp(
      r'"contextJSON":"((?:\\.|[^"\\])*)"\}\]\],\["NavigationMetrics',
    ).firstMatch(html);
    if (contextMatch == null) return null;

    try {
      final decoded = jsonDecode('"${contextMatch.group(1)!}"');
      if (decoded is String) {
        final media = jsonDecode(decoded);
        if (media is Map<String, dynamic>) return media;
      }
    } catch (_) {
      return null;
    }

    return null;
  }

  static ExtractedMedia _parseLegacyMedia(Map<String, dynamic> context) {
    final gql = context['gql_data'];
    final media = gql is Map<String, dynamic>
        ? (gql['shortcode_media'] ?? gql['xdt_shortcode_media'])
        : context['shortcode_media'];

    if (media is! Map<String, dynamic>) {
      throw EmbedExtractionException('Legacy embed payload is missing media data.');
    }

    final author = _readUsername(media['owner']) ?? '';
    final title = _readCaption(media) ?? 'Instagram Post';
    final sidecar = media['edge_sidecar_to_children'];
    final edges = sidecar is Map<String, dynamic>
        ? sidecar['edges']
        : null;

    if (edges is List && edges.isNotEmpty) {
      final items = <ExtractedMediaItem>[];
      for (var i = 0; i < edges.length; i++) {
        final node = (edges[i] as Map<String, dynamic>?)?['node'];
        if (node is! Map<String, dynamic>) continue;
        items.add(_legacyNodeToItem(node, index: i + 1));
      }
      if (items.isEmpty) {
        throw EmbedExtractionException('Carousel embed did not include downloadable items.');
      }
      return ExtractedMedia(
        title: title,
        author: author,
        items: items,
        thumbnail: items.first.thumbnail ?? items.first.url,
        isReel: _looksLikeReel(media),
        isCarousel: true,
      );
    }

    if (media['is_video'] == true) {
      final videoUrl = media['video_url'] as String?;
      if (videoUrl == null || videoUrl.isEmpty) {
        throw EmbedExtractionException('Video URL missing from embed payload.');
      }
      final versions = _legacyVideoVersions(media, fallbackUrl: videoUrl);
      return ExtractedMedia(
        title: title,
        author: author,
        items: versions,
        thumbnail: media['display_url'] as String?,
        duration: (media['video_duration'] as num?)?.toDouble(),
        isReel: _looksLikeReel(media),
      );
    }

    final imageUrl = media['display_url'] as String?;
    if (imageUrl == null || imageUrl.isEmpty) {
      throw EmbedExtractionException('Image URL missing from embed payload.');
    }

    return ExtractedMedia(
      title: title,
      author: author,
      items: [
        ExtractedMediaItem(
          type: 'image',
          url: imageUrl,
          ext: 'jpg',
          thumbnail: imageUrl,
        ),
      ],
      thumbnail: imageUrl,
    );
  }

  static ExtractedMedia _parseModernMedia(Map<String, dynamic> context) {
    final author = _readUsername(context['user']) ??
        _readUsername(context['owner']) ??
        '';
    final title = _readCaption(context) ?? 'Instagram Post';
    final carousel = context['carousel_media'];

    if (carousel is List && carousel.isNotEmpty) {
      final items = <ExtractedMediaItem>[];
      for (var i = 0; i < carousel.length; i++) {
        final node = carousel[i];
        if (node is! Map<String, dynamic>) continue;
        items.add(_modernNodeToItem(node, index: i + 1));
      }
      if (items.isEmpty) {
        throw EmbedExtractionException('Carousel embed did not include downloadable items.');
      }
      return ExtractedMedia(
        title: title,
        author: author,
        items: items,
        thumbnail: items.first.thumbnail ?? items.first.url,
        isReel: _looksLikeReel(context),
        isCarousel: true,
      );
    }

    final videoVersions = context['video_versions'];
    if (videoVersions is List && videoVersions.isNotEmpty) {
      final items = _modernVideoVersions(videoVersions);
      return ExtractedMedia(
        title: title,
        author: author,
        items: items,
        thumbnail: _bestImageCandidate(context['image_versions2']),
        duration: (context['video_duration'] as num?)?.toDouble(),
        isReel: _looksLikeReel(context),
      );
    }

    final imageUrl = _bestImageCandidate(context['image_versions2']);
    if (imageUrl != null && imageUrl.isNotEmpty) {
      return ExtractedMedia(
        title: title,
        author: author,
        items: [
          ExtractedMediaItem(
            type: 'image',
            url: imageUrl,
            ext: 'jpg',
            thumbnail: imageUrl,
          ),
        ],
        thumbnail: imageUrl,
      );
    }

    throw EmbedExtractionException('Unsupported or empty embed media payload.');
  }

  static ExtractedMediaItem _legacyNodeToItem(
    Map<String, dynamic> node, {
    required int index,
  }) {
    final imageUrl = node['display_url'] as String?;
    if (node['is_video'] == true) {
      final videoUrl = node['video_url'] as String?;
      if (videoUrl != null && videoUrl.isNotEmpty) {
        return ExtractedMediaItem(
          type: 'video',
          url: videoUrl,
          ext: 'mp4',
          thumbnail: imageUrl,
          height: _legacyBestVideoHeight(node),
        );
      }
    }

    if (imageUrl == null || imageUrl.isEmpty) {
      throw EmbedExtractionException('Carousel item $index is missing media URLs.');
    }

    return ExtractedMediaItem(
      type: 'image',
      url: imageUrl,
      ext: 'jpg',
      thumbnail: imageUrl,
    );
  }

  static ExtractedMediaItem _modernNodeToItem(
    Map<String, dynamic> node, {
    required int index,
  }) {
    final imageUrl = _bestImageCandidate(node['image_versions2']);
    final videoVersions = node['video_versions'];
    if (videoVersions is List && videoVersions.isNotEmpty) {
      final best = _pickBestVideoVersion(videoVersions);
      final url = best['url'] as String?;
      if (url != null && url.isNotEmpty) {
        return ExtractedMediaItem(
          type: 'video',
          url: url,
          ext: 'mp4',
          thumbnail: imageUrl,
          width: (best['width'] as num?)?.toInt(),
          height: (best['height'] as num?)?.toInt(),
        );
      }
    }

    if (imageUrl == null || imageUrl.isEmpty) {
      throw EmbedExtractionException('Carousel item $index is missing media URLs.');
    }

    return ExtractedMediaItem(
      type: 'image',
      url: imageUrl,
      ext: 'jpg',
      thumbnail: imageUrl,
    );
  }

  static List<ExtractedMediaItem> _legacyVideoVersions(
    Map<String, dynamic> media, {
    required String fallbackUrl,
  }) {
    final versions = media['video_versions'];
    if (versions is! List || versions.isEmpty) {
      return [
        ExtractedMediaItem(
          type: 'video',
          url: fallbackUrl,
          ext: 'mp4',
          thumbnail: media['display_url'] as String?,
          height: 720,
        ),
      ];
    }

    return _modernVideoVersions(versions);
  }

  static List<ExtractedMediaItem> _modernVideoVersions(List<dynamic> versions) {
    final parsed = <ExtractedMediaItem>[];
    for (final version in versions) {
      if (version is! Map<String, dynamic>) continue;
      final url = version['url'] as String?;
      if (url == null || url.isEmpty) continue;
      parsed.add(
        ExtractedMediaItem(
          type: 'video',
          url: url,
          ext: 'mp4',
          width: (version['width'] as num?)?.toInt(),
          height: (version['height'] as num?)?.toInt(),
        ),
      );
    }

    if (parsed.isEmpty) {
      throw EmbedExtractionException('Video versions missing from embed payload.');
    }

    parsed.sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));
    return parsed;
  }

  static Map<String, dynamic> _pickBestVideoVersion(List<dynamic> versions) {
    Map<String, dynamic>? best;
    var bestArea = -1;
    for (final version in versions) {
      if (version is! Map<String, dynamic>) continue;
      final width = (version['width'] as num?)?.toInt() ?? 0;
      final height = (version['height'] as num?)?.toInt() ?? 0;
      final area = width * height;
      if (area >= bestArea) {
        bestArea = area;
        best = version;
      }
    }
    return best ?? versions.first as Map<String, dynamic>;
  }

  static int? _legacyBestVideoHeight(Map<String, dynamic> node) {
    final versions = node['video_versions'];
    if (versions is! List || versions.isEmpty) return null;
    return (_pickBestVideoVersion(versions)['height'] as num?)?.toInt();
  }

  static String? _bestImageCandidate(dynamic imageVersions) {
    if (imageVersions is! Map<String, dynamic>) return null;
    final candidates = imageVersions['candidates'];
    if (candidates is! List || candidates.isEmpty) return null;

    Map<String, dynamic>? best;
    var bestArea = -1;
    for (final candidate in candidates) {
      if (candidate is! Map<String, dynamic>) continue;
      final width = (candidate['width'] as num?)?.toInt() ?? 0;
      final height = (candidate['height'] as num?)?.toInt() ?? 0;
      final area = width * height;
      if (area >= bestArea) {
        bestArea = area;
        best = candidate;
      }
    }

    return best?['url'] as String? ??
        (candidates.first as Map<String, dynamic>?)?['url'] as String?;
  }

  static String? _readCaption(Map<String, dynamic> media) {
    final edgeCaption = media['edge_media_to_caption'];
    if (edgeCaption is Map<String, dynamic>) {
      final edges = edgeCaption['edges'];
      if (edges is List && edges.isNotEmpty) {
        final node = (edges.first as Map<String, dynamic>?)?['node'];
        if (node is Map<String, dynamic>) {
          final text = node['text'] as String?;
          if (text != null && text.trim().isNotEmpty) return text.trim();
        }
      }
    }

    final caption = media['caption'];
    if (caption is Map<String, dynamic>) {
      final text = caption['text'] as String?;
      if (text != null && text.trim().isNotEmpty) return text.trim();
    } else if (caption is String && caption.trim().isNotEmpty) {
      return caption.trim();
    }

    return null;
  }

  static String? _readUsername(dynamic owner) {
    if (owner is! Map<String, dynamic>) return null;
    final username = owner['username'] as String?;
    if (username == null || username.isEmpty) return null;
    return username;
  }

  static bool _looksLikeReel(Map<String, dynamic> media) {
    final productType = media['product_type'] as String?;
    if (productType == 'clips' || productType == 'igtv') return true;

    final typename = media['__typename'] as String?;
    return typename == 'GraphVideo' && media['is_video'] == true;
  }
}
