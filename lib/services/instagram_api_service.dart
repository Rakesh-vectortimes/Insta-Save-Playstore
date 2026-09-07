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
import 'image_upscale.dart';
import 'instagram_cache_service.dart';
import 'instagram_cdn_utils.dart';
import 'instagram_direct_service.dart';
import 'instagram_dp_webview_service.dart';
import 'instagram_session.dart';
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
        if (reel != null &&
            reel.downloadUrl.isNotEmpty &&
            InstagramCdnUtils.isLikelyMp4Video(reel.downloadUrl)) {
          _log('Cache hit for reel');
          return reel;
        }
      }
    } catch (e) {
      _log('Cache check failed: $e');
    }

    // 2) On-device embed parse (reliable progressive MP4)
    try {
      final result = await _direct.fetchReel(url);
      if (InstagramCdnUtils.isLikelyMp4Video(result.downloadUrl)) {
        _log('Embed extracted reel on-device');
        unawaited(_cache.saveCache(url, _cache.reelToCachePayload(result)));
        return result;
      }
    } catch (e) {
      _log('On-device reel failed: $e');
    }

    // 3) WebView extraction (device IP / session)
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

    // 4) API fallback
    return _fetchReelFromApi(url);
  }

  Future<PostResult> fetchPost(String url) async {
    try {
      final cached = await _cache.checkCache(url);
      if (cached != null) {
        final post = _cache.postFromCache(cached);
        if (post != null && _isUsablePost(post)) {
          _log('Cache hit for post');
          return post;
        }
      }
    } catch (e) {
      _log('Cache check failed: $e');
    }

    // Embed first — accurate for public posts/carousels (avoids WebView noise).
    try {
      final result = await _direct.fetchPost(url);
      if (_isUsablePost(result)) {
        _log('Embed extracted post on-device');
        unawaited(_cache.saveCache(url, _cache.postToCachePayload(result)));
        return result;
      }
    } catch (e) {
      _log('On-device post failed: $e');
    }

    // API — best for multi-item carousels.
    try {
      final apiPost = await _fetchPostFromApi(url);
      if (_isUsablePost(apiPost)) {
        unawaited(_cache.saveCache(url, _cache.postToCachePayload(apiPost)));
        return apiPost;
      }
    } catch (e) {
      _log('API post failed: $e');
    }

    try {
      _log('Trying WebView extraction for post');
      final web = await InstagramWebViewService.extract(url);
      final post = _postFromWebView(web);
      if (post != null && _isUsablePost(post)) {
        _log('WebView success for post');
        unawaited(_cache.saveCache(url, _cache.postToCachePayload(post)));
        return post;
      }
    } catch (e) {
      _log('WebView post failed: $e');
    }

    throw ApiException(
      message: 'Could not extract this post. It may be private or unavailable.',
      retryable: true,
    );
  }

  /// Stories via dedicated WebView interceptor (needs IG session).
  Future<({ReelResult? reel, PostResult? post})> fetchStory(String url) async {
    // Skip cache for stories — stale/wrong tray thumbs were being reused.
    _log('Trying dedicated story WebView');
    final result = await InstagramStoryService.extractStory(url);

    if (result?.requiresLogin == true) {
      throw ApiException(
        message:
            'Story downloads need Instagram login inside the app. '
            'Tap Log in, sign in, then try the story link again.',
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

    final mediaUrl = result!.mediaUrl!;
    if (result.mediaType == 'image') {
      final post = PostResult(
        type: PostType.image,
        title: 'Instagram Story',
        author: '',
        url: mediaUrl,
        thumbnail: result.thumbnailUrl ?? mediaUrl,
        ext: 'jpg',
      );
      return (reel: null, post: post);
    }

    final reel = ReelResult(
      title: 'Instagram Story',
      thumbnail: result.thumbnailUrl,
      duration: null,
      source: 'webview',
      formats: const ['mp4'],
      qualities: const ['720p'],
      downloadUrl: mediaUrl,
      downloads: [
        ReelDownloadOption(
          format: 'mp4',
          quality: 720,
          label: '720p',
          url: mediaUrl,
        ),
      ],
      originalUrl: url,
    );
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
    final sessionHeaders = await InstagramSession.apiSessionHeaders();

    ProfileResult? webProfile;
    try {
      final web = await InstagramDpWebViewService.extractDp(clean);
      if (web?.dpUrl != null && web!.dpUrl!.isNotEmpty) {
        _log(
          'DP WebView — isHd: ${web.isHd} '
          '${web.width}x${web.height} source: ${web.source}',
        );
        webProfile = ProfileResult(
          username: clean,
          fullName: web.fullName ?? '',
          dpUrl: web.dpUrl!,
          isPrivate: false,
          followers: 0,
          dpSize: web.width,
          lowQuality: !web.isHd,
          upscaleAvailable: !web.isHd,
          upscaleNote: web.isHd
              ? null
              : 'Only a tiny thumbnail is available. Soft enhance can’t add real detail — Open Instagram → log in once → search again for the sharp original.',
          source: web.source,
        );
        if (web.isHd) return webProfile;
      }
    } catch (e) {
      _log('DP WebView failed: $e');
    }

    _log(
      'DP API fallback (session header: ${sessionHeaders.isNotEmpty})',
    );
    try {
      final encoded = Uri.encodeComponent(clean);
      final response = await _dio.get<Map<String, dynamic>>(
        '/api/instagram/dp/$encoded',
        options: Options(
          headers: sessionHeaders.isEmpty ? null : sessionHeaders,
        ),
      );
      final data = response.data;
      if (data == null) {
        if (webProfile != null) return webProfile;
        throw ApiException(
          message:
              'Unable to retrieve the profile picture. Please check the username and try again.',
          retryable: true,
        );
      }

      final profile = ProfileResult.fromJson(data);
      if (profile.username.isEmpty || profile.dpUrl.isEmpty) {
        if (webProfile != null) return webProfile;
        throw ApiException(
          message:
              'Profile could not be found. Check the username and try again.',
          retryable: false,
          statusCode: 404,
        );
      }

      final apiLooksHd = !profile.lowQuality &&
          (profile.dpSize == null || profile.dpSize! >= 640) &&
          !profile.dpUrl.toLowerCase().contains('s150x150');

      if (webProfile != null && webProfile.lowQuality) {
        return ProfileResult(
          username: profile.username.isNotEmpty ? profile.username : clean,
          fullName: profile.fullName.isNotEmpty
              ? profile.fullName
              : webProfile.fullName,
          dpUrl: profile.dpUrl,
          isPrivate: profile.isPrivate,
          followers: profile.followers,
          dpSize: profile.dpSize ?? webProfile.dpSize,
          lowQuality: !apiLooksHd,
          upscaleAvailable:
              profile.upscaleAvailable || !apiLooksHd || webProfile.lowQuality,
          upscaleFactor: profile.upscaleFactor,
          estimatedUpscaledSize: profile.estimatedUpscaledSize,
          upscaleNote: apiLooksHd
              ? null
              : (profile.upscaleNote ?? webProfile.upscaleNote),
          source: sessionHeaders.isNotEmpty
              ? (profile.source ?? 'api_session')
              : (profile.source ?? 'api'),
        );
      }
      return profile;
    } on ApiException {
      if (webProfile != null) return webProfile;
      rethrow;
    } on DioException catch (e) {
      if (webProfile != null) return webProfile;
      throw ApiException.fromDioException(e, feature: 'dp');
    } catch (_) {
      if (webProfile != null) return webProfile;
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
    final wantUpscale = upscale == true;
    final urlLooksTiny = directUrl != null &&
        RegExp(r's(100|150|240|320)x\1', caseSensitive: false)
            .hasMatch(directUrl);

    final canUseDirect = directUrl != null &&
        directUrl.startsWith('http') &&
        !wantUpscale &&
        !urlLooksTiny &&
        preferDirect;
    if (canUseDirect) {
      try {
        final response = await Dio().get<List<int>>(
          directUrl,
          options: Options(
            responseType: ResponseType.bytes,
            headers: {
              ...InstagramCdnUtils.downloadHeaders,
            },
          ),
          onReceiveProgress: (received, total) {
            onProgress?.call(
              FileDownloadProgress(received: received, total: total),
            );
          },
        );
        var bytes = response.data ?? [];
        if (bytes.isNotEmpty) {
          final enhanced = await _ensureDpQuality(bytes, forceUpscale: false);
          return ProfilePictureDownloadResult(
            bytes: enhanced.bytes,
            wasUpscaled: enhanced.wasUpscaled,
          );
        }
      } catch (e) {
        _log('Direct DP download failed, using API: $e');
      }
    }

    try {
      final queryParams = <String, dynamic>{
        // Always ask server for upscale when we know source is tiny.
        'upscale': (wantUpscale || urlLooksTiny) ? 1 : 0,
      };

      final sessionHeaders = await InstagramSession.apiSessionHeaders();
      final encoded = Uri.encodeComponent(username);
      final response = await _dio.get<List<int>>(
        '/api/instagram/dp/$encoded/download',
        queryParameters: queryParams,
        options: Options(
          responseType: ResponseType.bytes,
          headers: sessionHeaders.isEmpty ? null : sessionHeaders,
        ),
        onReceiveProgress: (received, total) {
          onProgress?.call(
            FileDownloadProgress(received: received, total: total),
          );
        },
      );

      var bytes = response.data ?? [];
      if (bytes.isEmpty && directUrl != null) {
        // Fallback: pull the CDN thumb ourselves then upscale locally.
        try {
          final fallback = await Dio().get<List<int>>(
            directUrl,
            options: Options(
              responseType: ResponseType.bytes,
              headers: {...InstagramCdnUtils.downloadHeaders},
            ),
          );
          bytes = fallback.data ?? [];
        } catch (_) {}
      }

      if (bytes.isEmpty) {
        throw ApiException(
          message:
              'Unable to retrieve the profile picture. Please check the username and try again.',
          retryable: true,
        );
      }

      final serverUpscaled =
          response.headers.value('x-dp-upscaled')?.toLowerCase() == 'true';
      final enhanced = await _ensureDpQuality(
        bytes,
        forceUpscale: wantUpscale || urlLooksTiny,
      );

      return ProfilePictureDownloadResult(
        bytes: enhanced.bytes,
        wasUpscaled: serverUpscaled || enhanced.wasUpscaled,
      );
    } on ApiException {
      rethrow;
    } on DioException catch (e) {
      throw ApiException.fromDioException(e, feature: 'dp');
    }
  }

  Future<({List<int> bytes, bool wasUpscaled})> _ensureDpQuality(
    List<int> bytes, {
    required bool forceUpscale,
  }) async {
    // Tiny JPEG payloads (~3KB) are 100x100 thumbs — always enlarge on-device.
    final tinyPayload = bytes.length < 12000;
    if (!forceUpscale && !tinyPayload) {
      return (bytes: bytes, wasUpscaled: false);
    }
    try {
      final out = await ImageUpscale.upscaleJpegIfSmall(
        bytes,
        minEdge: 720,
        maxEdge: 1440,
      );
      final changed = out.length != bytes.length;
      if (changed) {
        _log('DP local upscale applied (${bytes.length} → ${out.length} bytes)');
      }
      return (bytes: out, wasUpscaled: changed);
    } catch (e) {
      _log('DP local upscale failed: $e');
      return (bytes: bytes, wasUpscaled: false);
    }
  }

  ReelResult? _reelFromWebView(
    WebViewExtractionResult? web,
    String originalUrl, {
    String titleFallback = 'Instagram Reel',
  }) {
    if (web == null || !web.hasMedia) return null;

    final videoUrl = web.videoUrl;
    if (videoUrl == null ||
        videoUrl.isEmpty ||
        !InstagramCdnUtils.isLikelyMp4Video(videoUrl)) {
      // Never treat an image / junk CDN URL as an mp4 reel.
      return null;
    }

    return ReelResult(
      title: web.title ?? titleFallback,
      thumbnail: web.thumbnailUrl,
      duration: null,
      source: 'webview',
      formats: const ['mp4'],
      qualities: const ['720p'],
      downloadUrl: videoUrl,
      downloads: [
        ReelDownloadOption(
          format: 'mp4',
          quality: 720,
          label: '720p',
          url: videoUrl,
        ),
      ],
      originalUrl: originalUrl,
    );
  }

  bool _isUsablePost(PostResult post) {
    if (post.isCarousel) {
      return post.items.isNotEmpty &&
          post.items.every((i) => i.url.isNotEmpty);
    }
    final url = post.url;
    if (url == null || url.isEmpty) return false;
    if (post.type == PostType.video) {
      return InstagramCdnUtils.isLikelyMp4Video(url);
    }
    return InstagramCdnUtils.isInstagramCdn(url) || url.startsWith('http');
  }

  PostResult? _postFromWebView(WebViewExtractionResult? web) {
    if (web == null || !web.hasMedia) return null;

    if (web.contentType == 'carousel' &&
        web.carouselUrls != null &&
        web.carouselUrls!.length > 1) {
      final items = <CarouselItem>[
        for (var i = 0; i < web.carouselUrls!.length; i++)
          CarouselItem(
            index: i + 1,
            type: InstagramCdnUtils.isLikelyMp4Video(web.carouselUrls![i])
                ? 'video'
                : 'image',
            url: web.carouselUrls![i],
            ext: InstagramCdnUtils.isLikelyMp4Video(web.carouselUrls![i])
                ? 'mp4'
                : 'jpg',
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

    if (web.videoUrl != null &&
        web.videoUrl!.isNotEmpty &&
        InstagramCdnUtils.isLikelyMp4Video(web.videoUrl!)) {
      return PostResult(
        type: PostType.video,
        title: web.title ?? 'Instagram Post',
        author: '',
        url: web.videoUrl,
        thumbnail: web.thumbnailUrl,
        ext: 'mp4',
      );
    }

    if (web.imageUrl != null &&
        web.imageUrl!.isNotEmpty &&
        InstagramCdnUtils.isLikelyImage(web.imageUrl!)) {
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
