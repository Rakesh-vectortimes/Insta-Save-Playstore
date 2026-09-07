import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'instagram_cdn_utils.dart';

class WebViewExtractionResult {
  const WebViewExtractionResult({
    this.videoUrl,
    this.imageUrl,
    this.carouselUrls,
    this.thumbnailUrl,
    this.title,
    required this.source,
    required this.contentType,
  });

  final String? videoUrl;
  final String? imageUrl;
  final List<String>? carouselUrls;
  final String? thumbnailUrl;
  final String? title;
  final String source; // 'webview'
  final String contentType; // 'video' | 'image' | 'carousel'

  bool get hasMedia =>
      (videoUrl != null && videoUrl!.isNotEmpty) ||
      (imageUrl != null && imageUrl!.isNotEmpty) ||
      (carouselUrls != null && carouselUrls!.isNotEmpty);
}

class InstagramWebViewService {
  static const Duration _timeout = Duration(seconds: 22);

  static void _captureUrl(
    String url,
    List<String> videoUrls,
    List<String> imageUrls,
  ) {
    if (InstagramCdnUtils.isLikelyMp4Video(url) && !videoUrls.contains(url)) {
      videoUrls.add(url);
      if (kDebugMode) {
        final preview = url.length > 80 ? url.substring(0, 80) : url;
        debugPrint('[WebView] Captured video URL: $preview');
      }
    } else if (InstagramCdnUtils.isLikelyImage(url) &&
        !imageUrls.contains(url)) {
      imageUrls.add(url);
    }
  }

  static bool _isLoginOrHome(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('/accounts/login') || lower.contains('/challenge/')) {
      return true;
    }
    // Bare feed home after redirect — not a media page.
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final path = uri.path.replaceAll(RegExp(r'/+$'), '');
    return path.isEmpty || path == '' || path == '/';
  }

  /// Extract media from any Instagram URL using a headless WebView.
  static Future<WebViewExtractionResult?> extract(String instagramUrl) async {
    final completer = Completer<WebViewExtractionResult?>();
    final capturedVideoUrls = <String>[];
    final capturedImageUrls = <String>[];
    var loginOrWrongPage = false;
    Timer? timeoutTimer;
    HeadlessInAppWebView? headlessWebView;

    void finish(WebViewExtractionResult? result) {
      if (!completer.isCompleted) {
        completer.complete(result);
      }
    }

    void resolveFromCaptured() {
      if (loginOrWrongPage &&
          capturedVideoUrls.isEmpty &&
          capturedImageUrls.isEmpty) {
        finish(null);
        return;
      }
      finish(_buildResult(capturedVideoUrls, capturedImageUrls));
    }

    headlessWebView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri(instagramUrl),
        headers: const {
          'User-Agent': InstagramCdnUtils.mobileUserAgent,
          'Accept-Language': 'en-US,en;q=0.9',
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        transparentBackground: true,
        disableContextMenu: true,
        supportZoom: false,
        useOnLoadResource: true,
        useShouldInterceptRequest: true,
        sharedCookiesEnabled: true,
        thirdPartyCookiesEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        cacheEnabled: true,
        userAgent: InstagramCdnUtils.mobileUserAgent,
      ),
      shouldInterceptRequest: (controller, request) async {
        final url = request.url.toString();
        if (_isLoginOrHome(url) &&
            !url.contains('/p/') &&
            !url.contains('/reel') &&
            !url.contains('/tv/')) {
          // Don't mark wrong page from subresource requests.
        }
        _captureUrl(url, capturedVideoUrls, capturedImageUrls);
        return null;
      },
      onLoadResource: (controller, resource) async {
        final url = resource.url?.toString();
        if (url == null || url.isEmpty) return;
        _captureUrl(url, capturedVideoUrls, capturedImageUrls);
      },
      onLoadStop: (controller, url) async {
        if (kDebugMode) {
          debugPrint('[WebView] Page loaded: $url');
        }
        final current = url?.toString() ?? '';
        if (current.contains('/accounts/login') ||
            current.contains('/challenge/')) {
          loginOrWrongPage = true;
          finish(null);
          return;
        }

        await Future<void>.delayed(const Duration(milliseconds: 1800));
        if (completer.isCompleted) return;

        try {
          final jsResult = await controller.evaluateJavascript(source: '''
            (function() {
              try {
                function unescapeIg(u) {
                  return (u || '').replace(/\\\\u0026/g, '&').replace(/\\\\\\//g, '/');
                }

                // Prefer video element with real CDN src.
                const video = document.querySelector('video');
                if (video) {
                  let src = video.currentSrc || video.src || '';
                  if (!src) {
                    const s = video.querySelector('source');
                    if (s) src = s.src || '';
                  }
                  if (src && (src.indexOf('cdninstagram') !== -1 || src.indexOf('fbcdn') !== -1) &&
                      src.indexOf('.mp4') !== -1) {
                    return JSON.stringify({
                      type: 'video',
                      url: src,
                      poster: video.poster || ''
                    });
                  }
                }

                // Parse embedded JSON for video_url / video_versions / carousel.
                const scripts = document.querySelectorAll('script');
                let bestVideo = null;
                let carousel = [];
                for (const script of scripts) {
                  const text = script.textContent || '';
                  if (text.length < 40) continue;

                  const videoMatch = text.match(/"video_url"\\s*:\\s*"([^"]+)"/);
                  if (videoMatch && videoMatch[1]) {
                    bestVideo = unescapeIg(videoMatch[1]);
                  }

                  const versions = text.match(/"url"\\s*:\\s*"(https:[^"]+\\\\/v\\\\/t50[^"]+\\.mp4[^"]*)"/);
                  if (versions && versions[1]) {
                    bestVideo = unescapeIg(versions[1]);
                  }

                  // Sidecar carousel display_url entries
                  const displayMatches = text.matchAll(/"display_url"\\s*:\\s*"([^"]+)"/g);
                  for (const m of displayMatches) {
                    const u = unescapeIg(m[1]);
                    if (u.indexOf('cdninstagram') !== -1 || u.indexOf('fbcdn') !== -1) {
                      if (carousel.indexOf(u) === -1) carousel.push(u);
                    }
                  }
                }

                if (bestVideo) {
                  return JSON.stringify({ type: 'video', url: bestVideo, poster: '' });
                }
                if (carousel.length > 1) {
                  return JSON.stringify({ type: 'carousel', urls: carousel });
                }
                if (carousel.length === 1) {
                  return JSON.stringify({ type: 'images', urls: carousel });
                }

                // Article main image (single post) — avoid story tray / avatars.
                const main = document.querySelector('article img[src*="cdninstagram"], main img[src*="cdninstagram"], article img[src*="fbcdn"]');
                if (main && main.src && main.src.indexOf('profile_pic') === -1) {
                  return JSON.stringify({ type: 'images', urls: [main.src] });
                }

                const og = document.querySelector('meta[property="og:image"]');
                if (og && og.content && og.content.indexOf('instagram.com/static') === -1) {
                  return JSON.stringify({ type: 'images', urls: [og.content] });
                }

                return null;
              } catch (e) {
                return JSON.stringify({ error: e.message });
              }
            })()
          ''');

          if (jsResult != null && jsResult.toString() != 'null') {
            final parsed = jsonDecode(jsResult.toString());
            if (parsed is Map) {
              if (parsed['type'] == 'video' && parsed['url'] is String) {
                _captureUrl(
                  parsed['url'] as String,
                  capturedVideoUrls,
                  capturedImageUrls,
                );
                final poster = parsed['poster'];
                if (poster is String && poster.isNotEmpty) {
                  _captureUrl(poster, capturedVideoUrls, capturedImageUrls);
                }
              } else if (parsed['type'] == 'carousel' &&
                  parsed['urls'] is List) {
                final urls = <String>[];
                for (final item in parsed['urls'] as List) {
                  if (item is String) {
                    _captureUrl(item, capturedVideoUrls, capturedImageUrls);
                    urls.add(item);
                  }
                }
                // Mark as intentional carousel via temporary multi capture.
                if (urls.length > 1 && !completer.isCompleted) {
                  finish(
                    WebViewExtractionResult(
                      carouselUrls: urls,
                      thumbnailUrl: urls.first,
                      source: 'webview',
                      contentType: 'carousel',
                    ),
                  );
                  return;
                }
              } else if (parsed['type'] == 'images' && parsed['urls'] is List) {
                for (final item in parsed['urls'] as List) {
                  if (item is String) {
                    _captureUrl(item, capturedVideoUrls, capturedImageUrls);
                  }
                }
              }
            }
          }
        } catch (e) {
          if (kDebugMode) {
            debugPrint('[WebView] JS extraction error: $e');
          }
        }

        resolveFromCaptured();
      },
      onReceivedError: (controller, request, error) {
        if (kDebugMode) {
          debugPrint('[WebView] Error: ${error.description}');
        }
        if (request.isForMainFrame == true &&
            capturedVideoUrls.isEmpty &&
            capturedImageUrls.isEmpty) {
          finish(null);
        }
      },
    );

    timeoutTimer = Timer(_timeout, () {
      if (kDebugMode) {
        debugPrint('[WebView] Timeout — resolving with captured media');
      }
      resolveFromCaptured();
    });

    try {
      await headlessWebView.run();
      return await completer.future;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[WebView] Failed to start: $e');
      }
      return null;
    } finally {
      timeoutTimer.cancel();
      try {
        await headlessWebView.dispose();
      } catch (_) {}
    }
  }

  static WebViewExtractionResult? _buildResult(
    List<String> videoUrls,
    List<String> imageUrls,
  ) {
    final bestVideo = InstagramCdnUtils.pickBestVideo(videoUrls);
    if (bestVideo != null) {
      final thumb = InstagramCdnUtils.pickBestImage(imageUrls);
      return WebViewExtractionResult(
        videoUrl: bestVideo,
        thumbnailUrl: thumb,
        source: 'webview',
        contentType: 'video',
      );
    }

    final bestImage = InstagramCdnUtils.pickBestImage(imageUrls);
    if (bestImage == null) return null;

    // Do NOT invent carousels from arbitrary page images — that caused
    // Instagram logo / feed noise to be treated as posts.
    return WebViewExtractionResult(
      imageUrl: bestImage,
      thumbnailUrl: bestImage,
      source: 'webview',
      contentType: 'image',
    );
  }
}
