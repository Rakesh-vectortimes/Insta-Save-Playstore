import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

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
  static const Duration _timeout = Duration(seconds: 20);

  static bool _isCdnVideoUrl(String url) {
    final lower = url.toLowerCase();
    final isCdn = lower.contains('cdninstagram.com') ||
        lower.contains('fbcdn.net') ||
        lower.contains('instagram.f');
    if (!isCdn) return false;
    return lower.contains('.mp4') ||
        lower.contains('video') ||
        lower.contains('byterange') ||
        lower.contains('/v/');
  }

  static bool _isCdnImageUrl(String url) {
    final lower = url.toLowerCase();
    final isCdn = lower.contains('cdninstagram.com') ||
        lower.contains('fbcdn.net') ||
        lower.contains('instagram.f');
    if (!isCdn) return false;
    return lower.contains('.jpg') ||
        lower.contains('.jpeg') ||
        lower.contains('.webp') ||
        lower.contains('t51.') ||
        lower.contains('e35') ||
        lower.contains('e15');
  }

  static void _captureUrl(
    String url,
    List<String> videoUrls,
    List<String> imageUrls,
  ) {
    if (_isCdnVideoUrl(url) && !videoUrls.contains(url)) {
      videoUrls.add(url);
      if (kDebugMode) {
        final preview = url.length > 80 ? url.substring(0, 80) : url;
        debugPrint('[WebView] Captured video URL: $preview');
      }
    } else if (_isCdnImageUrl(url) && !imageUrls.contains(url)) {
      imageUrls.add(url);
    }
  }

  /// Extract media from any Instagram URL using a headless WebView.
  static Future<WebViewExtractionResult?> extract(String instagramUrl) async {
    final completer = Completer<WebViewExtractionResult?>();
    final capturedVideoUrls = <String>[];
    final capturedImageUrls = <String>[];
    Timer? timeoutTimer;
    HeadlessInAppWebView? headlessWebView;

    void finish(WebViewExtractionResult? result) {
      if (!completer.isCompleted) {
        completer.complete(result);
      }
    }

    void resolveFromCaptured() {
      finish(
        _buildResult(
          capturedVideoUrls,
          capturedImageUrls,
        ),
      );
    }

    headlessWebView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri(instagramUrl),
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
              'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
              'Mobile/15E148 Safari/604.1',
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
        userAgent:
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
      ),
      shouldInterceptRequest: (controller, request) async {
        _captureUrl(
          request.url.toString(),
          capturedVideoUrls,
          capturedImageUrls,
        );
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

        await Future<void>.delayed(const Duration(milliseconds: 1500));

        try {
          final jsResult = await controller.evaluateJavascript(source: '''
            (function() {
              try {
                const video = document.querySelector('video');
                if (video && video.src && (video.src.includes('cdninstagram') || video.src.includes('fbcdn'))) {
                  return JSON.stringify({
                    type: 'video',
                    url: video.src,
                    poster: video.poster || ''
                  });
                }

                const sources = document.querySelectorAll('video source');
                for (const s of sources) {
                  if (s.src && (s.src.includes('cdninstagram') || s.src.includes('fbcdn'))) {
                    return JSON.stringify({ type: 'video', url: s.src });
                  }
                }

                const scripts = document.querySelectorAll('script');
                for (const script of scripts) {
                  const text = script.textContent || '';
                  if (text.includes('video_url') || text.includes('video_versions')) {
                    const videoMatch = text.match(/"video_url"\\s*:\\s*"([^"]+)"/);
                    if (videoMatch && videoMatch[1]) {
                      return JSON.stringify({
                        type: 'video',
                        url: videoMatch[1].replace(/\\u0026/g, '&').replace(/\\//g, '/')
                      });
                    }
                  }
                }

                const imgs = document.querySelectorAll('img[src*="cdninstagram"], img[src*="fbcdn"]');
                if (imgs.length > 0) {
                  const urls = Array.from(imgs)
                    .map(i => i.src)
                    .filter(s => s && (s.includes('cdninstagram') || s.includes('fbcdn')));
                  if (urls.length > 0) {
                    return JSON.stringify({ type: 'images', urls: urls });
                  }
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
        if (request.isForMainFrame == true && capturedVideoUrls.isEmpty) {
          // Keep waiting for timeout if we already captured media.
          if (capturedImageUrls.isEmpty) {
            finish(null);
          }
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
      final result = await completer.future;
      return result;
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
    if (videoUrls.isNotEmpty) {
      final bestVideo = videoUrls.reduce(
        (a, b) => a.length >= b.length ? a : b,
      );
      return WebViewExtractionResult(
        videoUrl: bestVideo,
        thumbnailUrl: imageUrls.isNotEmpty ? imageUrls.first : null,
        source: 'webview',
        contentType: 'video',
      );
    }

    if (imageUrls.isEmpty) return null;

    // Prefer larger looking image URLs for single-image posts.
    final sortedImages = List<String>.from(imageUrls)
      ..sort((a, b) => b.length.compareTo(a.length));

    if (sortedImages.length > 1) {
      return WebViewExtractionResult(
        carouselUrls: sortedImages,
        thumbnailUrl: sortedImages.first,
        source: 'webview',
        contentType: 'carousel',
      );
    }

    return WebViewExtractionResult(
      imageUrl: sortedImages.first,
      thumbnailUrl: sortedImages.first,
      source: 'webview',
      contentType: 'image',
    );
  }
}
