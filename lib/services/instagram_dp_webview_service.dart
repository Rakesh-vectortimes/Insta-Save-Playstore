import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class DpExtractionResult {
  const DpExtractionResult({
    this.dpUrl,
    this.username,
    this.fullName,
    required this.isHd,
    required this.source,
  });

  final String? dpUrl;
  final String? username;
  final String? fullName;
  final bool isHd;
  final String source; // 'webview_hd' | 'webview_standard'
}

class InstagramDpWebViewService {
  static const Duration _timeout = Duration(seconds: 15);
  static const _userAgent =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
      'Mobile/15E148 Safari/604.1';

  static bool _isHighResDpUrl(String url) {
    final lower = url.toLowerCase();
    final isCdn =
        lower.contains('cdninstagram.com') || lower.contains('fbcdn.net');
    if (!isCdn) return false;
    if (lower.contains('s150x150')) return false;
    return lower.contains('profile_pic') ||
        lower.contains('s640x640') ||
        lower.contains('s1080x1080') ||
        lower.contains('s320x320');
  }

  static bool _isAnyDpUrl(String url) {
    final lower = url.toLowerCase();
    return (lower.contains('cdninstagram.com') ||
            lower.contains('fbcdn.net')) &&
        lower.contains('profile_pic');
  }

  static int _qualityScore(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('s1080x1080')) return 1080;
    if (lower.contains('s640x640')) return 640;
    if (lower.contains('s320x320')) return 320;
    if (lower.contains('s150x150')) return 150;
    if (_isHighResDpUrl(url)) return 500;
    return 200;
  }

  static Future<DpExtractionResult?> extractDp(String username) async {
    final completer = Completer<DpExtractionResult?>();
    final capturedDpUrls = <String>[];
    Timer? timeoutTimer;
    HeadlessInAppWebView? headlessWebView;
    final profileUrl = 'https://www.instagram.com/$username/';

    void finish(DpExtractionResult? result) {
      if (!completer.isCompleted) completer.complete(result);
    }

    void resolve() {
      if (capturedDpUrls.isEmpty) {
        finish(null);
        return;
      }
      capturedDpUrls.sort((a, b) => _qualityScore(b).compareTo(_qualityScore(a)));
      final bestUrl = capturedDpUrls.first;
      final isHd = _qualityScore(bestUrl) >= 320;
      finish(
        DpExtractionResult(
          dpUrl: bestUrl,
          username: username,
          isHd: isHd,
          source: isHd ? 'webview_hd' : 'webview_standard',
        ),
      );
    }

    headlessWebView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri(profileUrl),
        headers: const {'User-Agent': _userAgent},
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        sharedCookiesEnabled: true,
        thirdPartyCookiesEnabled: true,
        useOnLoadResource: true,
        useShouldInterceptRequest: true,
        userAgent: _userAgent,
      ),
      shouldInterceptRequest: (controller, request) async {
        final url = request.url.toString();
        if (_isHighResDpUrl(url)) {
          if (kDebugMode) {
            final preview = url.length > 70 ? url.substring(0, 70) : url;
            debugPrint('[DP WebView] HD profile pic: $preview');
          }
          if (!capturedDpUrls.contains(url)) capturedDpUrls.insert(0, url);
        } else if (_isAnyDpUrl(url)) {
          if (kDebugMode) {
            final preview = url.length > 70 ? url.substring(0, 70) : url;
            debugPrint('[DP WebView] Profile pic: $preview');
          }
          if (!capturedDpUrls.contains(url)) capturedDpUrls.add(url);
        }
        return null;
      },
      onLoadResource: (controller, resource) async {
        final url = resource.url?.toString();
        if (url == null) return;
        if (_isHighResDpUrl(url) && !capturedDpUrls.contains(url)) {
          capturedDpUrls.insert(0, url);
        } else if (_isAnyDpUrl(url) && !capturedDpUrls.contains(url)) {
          capturedDpUrls.add(url);
        }
      },
      onLoadStop: (controller, url) async {
        if (completer.isCompleted) return;
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        if (completer.isCompleted) return;

        try {
          final jsResult = await controller.evaluateJavascript(source: '''
            (function() {
              try {
                const imgs = document.querySelectorAll('img');
                let bestUrl = null;
                let bestSize = 0;
                for (const img of imgs) {
                  const src = img.src || '';
                  if ((src.includes('cdninstagram') || src.includes('fbcdn')) &&
                      (src.includes('profile_pic') || img.alt)) {
                    const srcset = img.srcset || '';
                    if (srcset) {
                      const parts = srcset.split(',');
                      for (const part of parts) {
                        const bits = part.trim().split(' ');
                        const srcUrl = bits[0];
                        const sizeNum = parseInt(bits[1], 10) || 0;
                        if (sizeNum > bestSize && srcUrl) {
                          bestSize = sizeNum;
                          bestUrl = srcUrl;
                        }
                      }
                    }
                    if (!bestUrl && src.includes('profile_pic')) bestUrl = src;
                  }
                }
                if (bestUrl) {
                  return JSON.stringify({ dpUrl: bestUrl, isHd: bestSize > 150 });
                }
                const jsonLd = document.querySelector('script[type="application/ld+json"]');
                if (jsonLd && jsonLd.textContent) {
                  const data = JSON.parse(jsonLd.textContent);
                  if (data.image) {
                    return JSON.stringify({
                      dpUrl: typeof data.image === 'string' ? data.image : data.image.url,
                      name: data.name,
                      isHd: false
                    });
                  }
                }
                const ogImage = document.querySelector('meta[property="og:image"]');
                if (ogImage && ogImage.content) {
                  return JSON.stringify({ dpUrl: ogImage.content, isHd: false });
                }
                return null;
              } catch (e) {
                return JSON.stringify({ error: e.message });
              }
            })()
          ''');

          if (jsResult != null && jsResult.toString() != 'null') {
            final parsed = jsonDecode(jsResult.toString());
            if (parsed is Map && parsed['dpUrl'] is String) {
              var extractedUrl = parsed['dpUrl'] as String;
              extractedUrl = extractedUrl
                  .replaceAll(r'\/', '/')
                  .replaceAll(r'\u0026', '&');
              if (!capturedDpUrls.contains(extractedUrl)) {
                capturedDpUrls.add(extractedUrl);
              }
            }
          }
        } catch (e) {
          if (kDebugMode) debugPrint('[DP WebView] JS error: $e');
        }

        resolve();
      },
      onReceivedError: (controller, request, error) {
        if (kDebugMode) debugPrint('[DP WebView] Error: ${error.description}');
        if (request.isForMainFrame == true && capturedDpUrls.isEmpty) {
          finish(null);
        }
      },
    );

    timeoutTimer = Timer(_timeout, () {
      if (kDebugMode) debugPrint('[DP WebView] Timeout');
      resolve();
    });

    try {
      await headlessWebView.run();
      return await completer.future;
    } catch (e) {
      if (kDebugMode) debugPrint('[DP WebView] Failed to start: $e');
      return null;
    } finally {
      timeoutTimer.cancel();
      try {
        await headlessWebView.dispose();
      } catch (_) {}
    }
  }
}
