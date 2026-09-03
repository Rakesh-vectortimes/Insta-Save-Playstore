import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../models/carousel_item.dart';
import '../models/post_result.dart';
import '../models/reel_result.dart';

class InstagramCacheService {
  InstagramCacheService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: AppConstants.apiBaseUrl,
                connectTimeout: const Duration(seconds: 3),
                sendTimeout: const Duration(seconds: 3),
                receiveTimeout: const Duration(seconds: 3),
                headers: {'Content-Type': 'application/json'},
              ),
            );

  final Dio _dio;

  Future<Map<String, dynamic>?> checkCache(String url) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/instagram/cache/check',
        data: {'url': url},
      );
      final data = response.data;
      if (data == null) return null;
      if (data['source'] == 'cache' || data['cached'] == true) {
        return data;
      }
      // Some backends return the cached payload directly.
      if (data['downloadUrl'] != null ||
          data['url'] != null ||
          data['items'] is List) {
        return data;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Cache] check failed (non-fatal): $e');
      }
    }
    return null;
  }

  Future<void> saveCache(String url, Map<String, dynamic> payload) async {
    try {
      await _dio.post<dynamic>(
        '/api/instagram/cache/save',
        data: {
          'url': url,
          ...payload,
        },
        options: Options(
          sendTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Cache] save failed (non-fatal): $e');
      }
    }
  }

  ReelResult? reelFromCache(Map<String, dynamic> data, String originalUrl) {
    try {
      if ((data['downloadUrl'] as String?)?.isNotEmpty == true ||
          (data['downloads'] is List && (data['downloads'] as List).isNotEmpty)) {
        return ReelResult.fromJson(data, originalUrl).copyWithSource(
          data['source'] as String? ?? 'cache',
        );
      }

      final url = data['url'] as String? ?? data['videoUrl'] as String?;
      if (url == null || url.isEmpty) return null;

      return ReelResult(
        title: data['title'] as String? ?? 'Instagram Reel',
        thumbnail: data['thumbnail'] as String? ?? data['thumbnailUrl'] as String?,
        duration: (data['duration'] as num?)?.toDouble(),
        source: data['source'] as String? ?? 'cache',
        formats: const ['mp4'],
        qualities: const ['720p'],
        downloadUrl: url,
        downloads: [
          ReelDownloadOption(
            format: 'mp4',
            quality: 720,
            label: '720p',
            url: url,
          ),
        ],
        originalUrl: originalUrl,
      );
    } catch (_) {
      return null;
    }
  }

  PostResult? postFromCache(Map<String, dynamic> data) {
    try {
      if (data['type'] != null || data['items'] is List) {
        return PostResult.fromJson(data);
      }

      final items = data['items'];
      if (items is List && items.isNotEmpty) {
        return PostResult.fromJson({
          'type': 'carousel',
          'title': data['title'] ?? 'Instagram Post',
          'author': data['author'] ?? '',
          'count': items.length,
          'items': items,
        });
      }

      final url = data['url'] as String? ?? data['imageUrl'] as String?;
      if (url == null || url.isEmpty) return null;
      final isVideo = (data['contentType'] as String?) == 'video' ||
          url.contains('.mp4');
      return PostResult(
        type: isVideo ? PostType.video : PostType.image,
        title: data['title'] as String? ?? 'Instagram Post',
        author: data['author'] as String? ?? '',
        url: url,
        thumbnail: data['thumbnail'] as String? ??
            data['thumbnailUrl'] as String? ??
            url,
        ext: isVideo ? 'mp4' : 'jpg',
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> reelToCachePayload(ReelResult reel) {
    return {
      'title': reel.title,
      'thumbnail': reel.thumbnail,
      'duration': reel.duration,
      'source': 'webview',
      'formats': reel.formats,
      'qualities': reel.qualities,
      'downloadUrl': reel.downloadUrl,
      'downloads': reel.downloads
          .map(
            (d) => {
              'format': d.format,
              'quality': d.quality,
              'label': d.label,
              'url': d.url,
            },
          )
          .toList(),
      'type': 'video',
      'url': reel.downloadUrl,
    };
  }

  Map<String, dynamic> postToCachePayload(PostResult post) {
    if (post.isCarousel) {
      return {
        'type': 'carousel',
        'title': post.title,
        'author': post.author,
        'count': post.count ?? post.items.length,
        'items': post.items
            .map(
              (item) => {
                'index': item.index,
                'type': item.type,
                'url': item.url,
                'ext': item.ext,
                'thumbnail': item.thumbnail,
              },
            )
            .toList(),
        'source': 'webview',
      };
    }

    return {
      'type': post.type == PostType.video ? 'video' : 'image',
      'title': post.title,
      'author': post.author,
      'url': post.url,
      'thumbnail': post.thumbnail,
      'ext': post.ext,
      'source': 'webview',
    };
  }

  List<CarouselItem> carouselFromUrls(List<String> urls) {
    return [
      for (var i = 0; i < urls.length; i++)
        CarouselItem(
          index: i + 1,
          type: urls[i].contains('.mp4') ? 'video' : 'image',
          url: urls[i],
          ext: urls[i].contains('.mp4') ? 'mp4' : 'jpg',
          thumbnail: urls[i],
        ),
    ];
  }
}

extension on ReelResult {
  ReelResult copyWithSource(String source) {
    return ReelResult(
      title: title,
      thumbnail: thumbnail,
      duration: duration,
      source: source,
      formats: formats,
      qualities: qualities,
      downloadUrl: downloadUrl,
      downloads: downloads,
      originalUrl: originalUrl,
    );
  }
}
