import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class StoryExtractionResult {
  const StoryExtractionResult({
    this.mediaUrl,
    this.thumbnailUrl,
    required this.mediaType,
    this.requiresLogin = false,
  });

  final String? mediaUrl;
  final String? thumbnailUrl;
  final String mediaType; // 'video' | 'image' | 'unknown'
  final bool requiresLogin;
}

class InstagramStoryService {
  static const Duration _timeout = Duration(seconds: 20);
  static const _userAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
      'Mobile/15E148 Safari/604.1';

  static bool _isStoryVideoUrl(String url) {
    final lower = url.toLowerCase();
    final isCdn =
        lower.contains('cdninstagram.com') || lower.contains('fbcdn.net');
    if (!isCdn) return false;
    return lower.contains('.mp4') ||
        lower.contains('video') ||
        lower.contains('byterange');
  }

  static bool _isStoryImageUrl(String url) {
    final lower = url.toLowerCase();
    final isCdn =
        lower.contains('cdninstagram.com') || lower.contains('fbcdn.net');
    if (!isCdn) return false;
    if (lower.contains('profile_pic') ||
        lower.contains('s150x150') ||
        lower.contains('s320x320')) {
      return false;
    }
    return lower.contains('.jpg') ||
        lower.contains('.jpeg') ||
        lower.contains('.webp') ||
        lower.contains('t51.') ||
        lower.contains('e35') ||
        lower.contains('e15');
  }

  static bool _isLoginUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('/accounts/login') || lower.contains('/challenge/');
  }

  static Future<StoryExtractionResult?> extractStory(String storyUrl) async {
    final completer = Completer<StoryExtractionResult?>();
    String? capturedVideoUrl;
    final capturedImageUrls = <String>[];
    var loginPageDetected = false;
    Timer? timeoutTimer;
    HeadlessInAppWebView? headlessWebView;

    void finish(StoryExtractionResult? result) {
      if (!completer.isCompleted) completer.complete(result);
    }

    void resolveCaptured() {
      if (loginPageDetected) {
        finish(
          const StoryExtractionResult(
            mediaType: 'unknown',
            requiresLogin: true,
          ),
        );
        return;
      }
      if (capturedVideoUrl != null) {
        finish(
          StoryExtractionResult(
            mediaUrl: capturedVideoUrl,
            thumbnailUrl:
                capturedImageUrls.isNotEmpty ? capturedImageUrls.first : null,
            mediaType: 'video',
          ),
        );
      } else if (capturedImageUrls.isNotEmpty) {
        finish(
          StoryExtractionResult(
            mediaUrl: capturedImageUrls.first,
            mediaType: 'image',
          ),
        );
      } else {
        finish(null);
      }
    }

    headlessWebView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri(storyUrl),
        headers: const {'User-Agent': _userAgent},
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        sharedCookiesEnabled: true,
        thirdPartyCookiesEnabled: true,
        useOnLoadResource: true,
        useShouldInterceptRequest: true,
        userAgent: _userAgent,
      ),
      shouldInterceptRequest: (controller, request) async {
        final url = request.url.toString();
        if (_isLoginUrl(url)) {
          loginPageDetected = true;
          finish(
            const StoryExtractionResult(
              mediaType: 'unknown',
              requiresLogin: true,
            ),
          );
          return null;
        }
        if (_isStoryVideoUrl(url) && capturedVideoUrl == null) {
          capturedVideoUrl = url;
          if (kDebugMode) {
            final preview = url.length > 60 ? url.substring(0, 60) : url;
            debugPrint('[Story] Captured video: $preview');
          }
        }
        if (_isStoryImageUrl(url) && capturedImageUrls.length < 3) {
          capturedImageUrls.add(url);
          if (kDebugMode) {
            final preview = url.length > 60 ? url.substring(0, 60) : url;
            debugPrint('[Story] Captured image: $preview');
          }
        }
        return null;
      },
      onLoadResource: (controller, resource) async {
        final url = resource.url?.toString();
        if (url == null) return;
        if (_isStoryVideoUrl(url) && capturedVideoUrl == null) {
          capturedVideoUrl = url;
        }
        if (_isStoryImageUrl(url) && capturedImageUrls.length < 3) {
          capturedImageUrls.add(url);
        }
      },
      onLoadStop: (controller, url) async {
        if (completer.isCompleted) return;
        final currentUrl = url?.toString() ?? '';
        if (_isLoginUrl(currentUrl)) {
          loginPageDetected = true;
          finish(
            const StoryExtractionResult(
              mediaType: 'unknown',
              requiresLogin: true,
            ),
          );
          return;
        }

        await Future<void>.delayed(const Duration(milliseconds: 2000));
        if (completer.isCompleted) return;

        try {
          final jsResult = await controller.evaluateJavascript(source: '''
            (function() {
              const video = document.querySelector('video');
              if (video && video.src &&
                  (video.src.includes('cdninstagram') || video.src.includes('fbcdn'))) {
                return JSON.stringify({
                  type: 'video',
                  url: video.src,
                  poster: video.poster || ''
                });
              }
              const source = document.querySelector('video source');
              if (source && source.src) {
                return JSON.stringify({ type: 'video', url: source.src });
              }
              const imgs = document.querySelectorAll(
                'img[src*="cdninstagram"], img[src*="fbcdn"]'
              );
              const validImgs = Array.from(imgs)
                .map(function(i) { return i.src; })
                .filter(function(s) {
                  return s && s.indexOf('s150x150') === -1 &&
                    s.indexOf('profile_pic') === -1;
                });
              if (validImgs.length > 0) {
                return JSON.stringify({ type: 'image', url: validImgs[0] });
              }
              return null;
            })()
          ''');

          if (jsResult != null && jsResult.toString() != 'null') {
            final parsed = jsonDecode(jsResult.toString());
            if (parsed is Map) {
              final mediaUrl = parsed['url'] as String?;
              if (parsed['type'] == 'video' && mediaUrl != null) {
                capturedVideoUrl ??= mediaUrl;
                final poster = parsed['poster'] as String?;
                if (poster != null &&
                    poster.isNotEmpty &&
                    capturedImageUrls.isEmpty) {
                  capturedImageUrls.add(poster);
                }
              } else if (parsed['type'] == 'image' && mediaUrl != null) {
                if (!capturedImageUrls.contains(mediaUrl)) {
                  capturedImageUrls.insert(0, mediaUrl);
                }
              }
            }
          }
        } catch (e) {
          if (kDebugMode) debugPrint('[Story] JS error: $e');
        }

        resolveCaptured();
      },
      onReceivedError: (controller, request, error) {
        if (kDebugMode) debugPrint('[Story] Error: ${error.description}');
        if (request.isForMainFrame == true &&
            capturedVideoUrl == null &&
            capturedImageUrls.isEmpty) {
          finish(null);
        }
      },
    );

    timeoutTimer = Timer(_timeout, () {
      if (kDebugMode) debugPrint('[Story] Timeout');
      resolveCaptured();
    });

    try {
      await headlessWebView.run();
      return await completer.future;
    } catch (e) {
      if (kDebugMode) debugPrint('[Story] Failed to start: $e');
      return null;
    } finally {
      timeoutTimer.cancel();
      try {
        await headlessWebView.dispose();
      } catch (_) {}
    }
  }
}
