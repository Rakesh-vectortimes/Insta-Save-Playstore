import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../models/carousel_item.dart';
import '../models/post_result.dart';
import '../models/profile_result.dart';
import '../models/reel_result.dart';
import 'download_service.dart';
import 'instagram_cache_service.dart';
import 'instagram_direct_service.dart';
import 'instagram_dp_webview_service.dart';
import 'instagram_story_service.dart';
import 'instagram_webview_service.dart';

final instagramApiServiceProvider = Provider<InstagramApiService>((ref) {
  return InstagramApiService(
    ref.watch(dioProvider),
    ref.watch(instagramDirectServiceProvider),
  );
});

class InstagramApiService {
  InstagramApiService(this._dio, this._direct)
      : _cache = InstagramCacheService(dio: _dio);

  final Dio _dio;
  final InstagramDirectService _direct;
  final InstagramCacheService _cache;

  Future<ReelResult> fetchReel(String url) async {
    // 1) Server cache (fast path)
    try {
      final cached = await _cache.checkCache(url);
      if (cached != null) {
        final reel = _cache.reelFromCache(cached, url);
        if (reel != null && reel.downloadUrl.isNotEmpty) {
          _log('Cache hit for reel');
          return reel;
        }
      }
    } catch (e) {
      _log('Cache check failed: $e');
    }

    // 2) WebView extraction (device IP / session)
    try {
      _log('Trying WebView extraction for reel');
      final web = await InstagramWebViewService.extract(url);
      final reel = _reelFromWebView(web, url);
      if (reel != null) {
        _log('WebView success for reel');
        unawaited(_cache.saveCache(url, _cache.reelToCachePayload(reel)));
        return reel;
      }
    } catch (e) {
      _log('WebView reel failed: $e');
    }

    // 3) Existing on-device embed parse
    try {
      final result = await _direct.fetchReel(url);
      _log('Embed extracted reel on-device');
      return result;
    } catch (e) {
      _log('On-device reel failed, using API fallback: $e');
    }

    // 4) API fallback
    return _fetchReelFromApi(url);
  }

  Future<PostResult> fetchPost(String url) async {
    try {
      final cached = await _cache.checkCache(url);
      if (cached != null) {
        final post = _cache.postFromCache(cached);
        if (post != null) {
          _log('Cache hit for post');
          return post;
        }
      }
    } catch (e) {
      _log('Cache check failed: $e');
    }

    try {
      _log('Trying WebView extraction for post');
      final web = await InstagramWebViewService.extract(url);
      final post = _postFromWebView(web);
      if (post != null) {
        _log('WebView success for post');
        unawaited(_cache.saveCache(url, _cache.postToCachePayload(post)));
        return post;
      }
    } catch (e) {
      _log('WebView post failed: $e');
    }

    try {
      final result = await _direct.fetchPost(url);
      _log('Embed extracted post on-device');
      return result;
    } catch (e) {
      _log('On-device post failed, using API fallback: $e');
    }

    return _fetchPostFromApi(url);
  }

  /// Stories via dedicated WebView interceptor (needs IG session).
  Future<({ReelResult? reel, PostResult? post})> fetchStory(String url) async {
    try {
      final cached = await _cache.checkCache(url);
      if (cached != null) {
        final reel = _cache.reelFromCache(cached, url);
        if (reel != null && reel.downloadUrl.isNotEmpty) {
          _log('Cache hit for story');
          return (reel: reel, post: null);
        }
        final post = _cache.postFromCache(cached);
        if (post != null) {
          return (reel: null, post: post);
        }
      }
    } catch (_) {}

    _log('Trying dedicated story WebView');
    final result = await InstagramStoryService.extractStory(url);

    if (result?.requiresLogin == true) {
      throw ApiException(
        message:
            'Story downloads need Instagram login. '
            'Log into Instagram in your browser, then try again.',
        retryable: false,
        reasonCode: 'story_requires_login',
        scopeLimited: true,
      );
    }

    if (result?.mediaUrl == null) {
      throw ApiException(
        message: 'Could not extract this story. It may have expired.',
        retryable: true,
        reasonCode: 'story_extraction_failed',
      );
    }

    if (result!.mediaType == 'image') {
      final post = PostResult(
        type: PostType.image,
        title: 'Instagram Story',
        author: '',
        url: result.mediaUrl,
        thumbnail: result.thumbnailUrl ?? result.mediaUrl,
        ext: 'jpg',
      );
      unawaited(_cache.saveCache(url, _cache.postToCachePayload(post)));
      return (reel: null, post: post);
    }

    final reel = ReelResult(
      title: 'Instagram Story',
      thumbnail: result.thumbnailUrl,
      duration: null,
      source: 'webview',
      formats: const ['mp4'],
      qualities: const ['720p'],
      downloadUrl: result.mediaUrl!,
      downloads: [
        ReelDownloadOption(
          format: 'mp4',
          quality: 720,
          label: '720p',
          url: result.mediaUrl!,
        ),
      ],
      originalUrl: url,
    );
    unawaited(_cache.saveCache(url, _cache.reelToCachePayload(reel)));
    return (reel: reel, post: null);
  }

  Future<List<int>> downloadCarouselZip(String url) async {
    try {
      final response = await _dio.post<List<int>>(
        '/api/instagram/carousel/zip',
        data: {'url': url},
        options: Options(responseType: ResponseType.bytes),
      );
      return response.data ?? [];
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<ProfileResult> fetchProfilePicture(String username) async {
    final clean = username.replaceAll('@', '').trim();

    try {
      final web = await InstagramDpWebViewService.extractDp(clean);
      if (web?.dpUrl != null && web!.dpUrl!.isNotEmpty) {
        _log('DP WebView success — isHd: ${web.isHd} source: ${web.source}');
        return ProfileResult(
          username: clean,
          fullName: web.fullName ?? '',
          dpUrl: web.dpUrl!,
          isPrivate: false,
          followers: 0,
          lowQuality: !web.isHd,
          upscaleAvailable: !web.isHd,
          upscaleNote: web.isHd
              ? null
              : 'Higher-resolution photo was not available. HD upscale can still run on download.',
          source: web.source,
        );
      }
    } catch (e) {
      _log('DP WebView failed: $e');
    }

    _log('DP falling back to API');
    try {
      final encoded = Uri.encodeComponent(clean);
      final response = await _dio.get<Map<String, dynamic>>(
        '/api/instagram/dp/$encoded',
      );
      final data = response.data;
      if (data == null) {
        throw ApiException(
          message:
              'Unable to retrieve the profile picture. Please check the username and try again.',
          retryable: true,
        );
      }

      final profile = ProfileResult.fromJson(data);
      if (profile.username.isEmpty || profile.dpUrl.isEmpty) {
        throw ApiException(
          message:
              'Profile could not be found. Check the username and try again.',
          retryable: false,
          statusCode: 404,
        );
      }
      return profile;
    } on ApiException {
      rethrow;
    } on DioException catch (e) {
      throw ApiException.fromDioException(e, feature: 'dp');
    } catch (_) {
      throw ApiException(
        message:
            'Unable to retrieve the profile picture. Please check the username and try again.',
        retryable: true,
      );
    }
  }

  Future<ProfilePictureDownloadResult> downloadProfilePicture(
    String username, {
    bool? upscale,
    String? directUrl,
    bool preferDirect = false,
    void Function(FileDownloadProgress progress)? onProgress,
  }) async {
    final canUseDirect = directUrl != null &&
        directUrl.startsWith('http') &&
        upscale != true &&
        (preferDirect || directUrl.isNotEmpty);
    if (canUseDirect) {
      try {
        final response = await Dio().get<List<int>>(
          directUrl,
          options: Options(
            responseType: ResponseType.bytes,
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
              'Referer': 'https://www.instagram.com/',
            },
          ),
          onReceiveProgress: (received, total) {
            onProgress?.call(
              FileDownloadProgress(received: received, total: total),
            );
          },
        );
        final bytes = response.data ?? [];
        if (bytes.isNotEmpty) {
          return ProfilePictureDownloadResult(
            bytes: bytes,
            wasUpscaled: false,
          );
        }
      } catch (e) {
        _log('Direct DP download failed, using API: $e');
      }
    }

    try {
      final queryParams = <String, dynamic>{};
      if (upscale != null) {
        queryParams['upscale'] = upscale ? 1 : 0;
      }

      final encoded = Uri.encodeComponent(username);
      final response = await _dio.get<List<int>>(
        '/api/instagram/dp/$encoded/download',
        queryParameters: queryParams.isEmpty ? null : queryParams,
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: (received, total) {
          onProgress?.call(
            FileDownloadProgress(received: received, total: total),
          );
        },
      );

      final bytes = response.data ?? [];
      if (bytes.isEmpty) {
        throw ApiException(
          message:
              'Unable to retrieve the profile picture. Please check the username and try again.',
          retryable: true,
        );
      }

      final wasUpscaled =
          response.headers.value('x-dp-upscaled')?.toLowerCase() == 'true';

      return ProfilePictureDownloadResult(
        bytes: bytes,
        wasUpscaled: wasUpscaled,
      );
    } on ApiException {
      rethrow;
    } on DioException catch (e) {
      throw ApiException.fromDioException(e, feature: 'dp');
    }
  }

  ReelResult? _reelFromWebView(
    WebViewExtractionResult? web,
    String originalUrl, {
    String titleFallback = 'Instagram Reel',
  }) {
    if (web == null || !web.hasMedia) return null;

    if (web.videoUrl != null && web.videoUrl!.isNotEmpty) {
      return ReelResult(
        title: web.title ?? titleFallback,
        thumbnail: web.thumbnailUrl,
        duration: null,
        source: 'webview',
        formats: const ['mp4'],
        qualities: const ['720p'],
        downloadUrl: web.videoUrl!,
        downloads: [
          ReelDownloadOption(
            format: 'mp4',
            quality: 720,
            label: '720p',
            url: web.videoUrl!,
          ),
        ],
        originalUrl: originalUrl,
      );
    }

    // Some "reels" may only expose an image fallback.
    if (web.imageUrl != null && web.imageUrl!.isNotEmpty) {
      return ReelResult(
        title: web.title ?? titleFallback,
        thumbnail: web.thumbnailUrl ?? web.imageUrl,
        duration: null,
        source: 'webview',
        formats: const ['mp4'],
        qualities: const ['720p'],
        downloadUrl: web.imageUrl!,
        downloads: [
          ReelDownloadOption(
            format: 'mp4',
            quality: 720,
            label: '720p',
            url: web.imageUrl!,
          ),
        ],
        originalUrl: originalUrl,
      );
    }

    return null;
  }

  PostResult? _postFromWebView(WebViewExtractionResult? web) {
    if (web == null || !web.hasMedia) return null;

    if (web.contentType == 'carousel' &&
        web.carouselUrls != null &&
        web.carouselUrls!.isNotEmpty) {
      final items = <CarouselItem>[
        for (var i = 0; i < web.carouselUrls!.length; i++)
          CarouselItem(
            index: i + 1,
            type: web.carouselUrls![i].contains('.mp4') ? 'video' : 'image',
            url: web.carouselUrls![i],
            ext: web.carouselUrls![i].contains('.mp4') ? 'mp4' : 'jpg',
            thumbnail: web.carouselUrls![i],
          ),
      ];
      return PostResult(
        type: PostType.carousel,
        title: web.title ?? 'Instagram Post',
        author: '',
        count: items.length,
        items: items,
      );
    }

    if (web.videoUrl != null && web.videoUrl!.isNotEmpty) {
      return PostResult(
        type: PostType.video,
        title: web.title ?? 'Instagram Post',
        author: '',
        url: web.videoUrl,
        thumbnail: web.thumbnailUrl,
        ext: 'mp4',
      );
    }

    if (web.imageUrl != null && web.imageUrl!.isNotEmpty) {
      return PostResult(
        type: PostType.image,
        title: web.title ?? 'Instagram Post',
        author: '',
        url: web.imageUrl,
        thumbnail: web.thumbnailUrl ?? web.imageUrl,
        ext: 'jpg',
      );
    }

    return null;
  }

  Future<ReelResult> _fetchReelFromApi(String url) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/instagram/reel',
        data: {'url': url},
      );
      return ReelResult.fromJson(response.data!, url);
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<PostResult> _fetchPostFromApi(String url) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/instagram/post',
        data: {'url': url},
      );
      return PostResult.fromJson(response.data!);
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  void _log(String message) {
    if (kDebugMode) {
      debugPrint('[InstagramApi] $message');
    }
  }
}
