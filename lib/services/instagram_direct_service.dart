import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/instagram_shortcode.dart';
import '../models/carousel_item.dart';
import '../models/post_result.dart';
import '../models/reel_result.dart';
import 'instagram_embed_extractor.dart';

final instagramDirectServiceProvider = Provider<InstagramDirectService>((ref) {
  return InstagramDirectService();
});

class InstagramDirectService {
  InstagramDirectService({Dio? dio}) : _dio = dio ?? _createDio();

  final Dio _dio;

  static Dio _createDio() {
    return Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 30),
        headers: const {
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
          'Accept-Language': 'en-US,en;q=0.9',
          'Cache-Control': 'max-age=0',
          'Sec-Fetch-Dest': 'document',
          'Sec-Fetch-Mode': 'navigate',
          'Sec-Fetch-Site': 'none',
          'Sec-Fetch-User': '?1',
          'Upgrade-Insecure-Requests': '1',
          'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
        },
      ),
    );
  }

  Future<ReelResult> fetchReel(String url) async {
    final media = await _extractMedia(url, expectReel: true);
    if (!media.isVideo) {
      throw EmbedExtractionException('Expected a reel but found non-video media.');
    }
    return _toReelResult(media, url);
  }

  Future<PostResult> fetchPost(String url) async {
    final media = await _extractMedia(url, expectReel: false);
    return _toPostResult(media);
  }

  Future<ExtractedMedia> _extractMedia(
    String url, {
    required bool expectReel,
  }) async {
    final shortcode = InstagramShortcode.fromUrl(url);
    if (shortcode == null) {
      throw EmbedExtractionException('Could not parse Instagram shortcode.');
    }

    final html = await _fetchEmbedHtml(shortcode);
    final media = InstagramEmbedExtractor.parseHtml(html);

    if (expectReel && !media.isReel && !media.isVideo) {
      throw EmbedExtractionException('URL is not a downloadable reel.');
    }

    return media;
  }

  Future<String> _fetchEmbedHtml(String shortcode) async {
    final embedUrl =
        'https://www.instagram.com/p/$shortcode/embed/captioned/';

    try {
      final response = await _dio.get<String>(
        embedUrl,
        options: Options(responseType: ResponseType.plain),
      );
      final html = response.data;
      if (html == null || html.isEmpty) {
        throw EmbedExtractionException('Instagram embed page was empty.');
      }
      return html;
    } on DioException catch (e) {
      throw EmbedExtractionException(
        e.message ?? 'Failed to reach Instagram embed page.',
      );
    }
  }

  ReelResult _toReelResult(ExtractedMedia media, String originalUrl) {
    final videoItems =
        media.items.where((item) => item.isVideo).toList(growable: false);
    final sourceItems = videoItems.isNotEmpty ? videoItems : media.items;

    final downloads = <ReelDownloadOption>[];
    final qualities = <String>{};
    for (final item in sourceItems) {
      final quality = item.height ?? 720;
      final label = '${quality}p';
      qualities.add(label);
      downloads.add(
        ReelDownloadOption(
          format: 'mp4',
          quality: quality,
          label: label,
          url: item.url,
        ),
      );
    }

    downloads.sort((a, b) => b.quality.compareTo(a.quality));
    final best = downloads.first;

    return ReelResult(
      title: media.title,
      thumbnail: media.thumbnail,
      duration: media.duration,
      source: 'device',
      formats: const ['mp4'],
      qualities: qualities.toList()..sort(),
      downloadUrl: best.url,
      downloads: downloads,
      originalUrl: originalUrl,
    );
  }

  PostResult _toPostResult(ExtractedMedia media) {
    if (media.isCarousel) {
      return PostResult(
        type: PostType.carousel,
        title: media.title,
        author: media.author,
        count: media.items.length,
        items: [
          for (var i = 0; i < media.items.length; i++)
            CarouselItem(
              index: i + 1,
              type: media.items[i].isVideo ? 'video' : 'image',
              url: media.items[i].url,
              ext: media.items[i].ext,
              thumbnail: media.items[i].thumbnail ?? media.items[i].url,
            ),
        ],
      );
    }

    final item = media.items.first;
    return PostResult(
      type: item.isVideo ? PostType.video : PostType.image,
      title: media.title,
      author: media.author,
      url: item.url,
      thumbnail: item.thumbnail ?? item.url,
      ext: item.ext,
    );
  }

  void debugLog(String message) {
    if (kDebugMode) {
      debugPrint('[InstagramDirect] $message');
    }
  }
}
