import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'instagram_cdn_utils.dart';

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
  static const Duration _timeout = Duration(seconds: 35);
  static const _igAppId = '936619743392459';

  static Future<bool> hasInstagramSession() async {
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri('https://www.instagram.com'),
      );
      return cookies.any(
        (c) => c.name == 'sessionid' && (c.value?.isNotEmpty ?? false),
      );
    } catch (_) {
      return false;
    }
  }

  static ({String? username, String? mediaId}) parseStoryUrl(String storyUrl) {
    final match = RegExp(
      r'instagram\.com/stories/([A-Za-z0-9._]+)/(\d+)',
      caseSensitive: false,
    ).firstMatch(storyUrl);
    if (match == null) {
      return (username: null, mediaId: null);
    }
    return (username: match.group(1), mediaId: match.group(2));
  }

  static bool _isLoginUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('/accounts/login') || lower.contains('/challenge/');
  }

  /// Extract story media via Instagram web API inside the app WebView session.
  /// Chrome login does NOT share cookies with the app — use in-app login.
  static Future<StoryExtractionResult?> extractStory(String storyUrl) async {
    final parsed = parseStoryUrl(storyUrl);
    final username = parsed.username;
    final mediaId = parsed.mediaId;

    if (!await hasInstagramSession()) {
      return const StoryExtractionResult(
        mediaType: 'unknown',
        requiresLogin: true,
      );
    }

    final completer = Completer<StoryExtractionResult?>();
    Timer? timeoutTimer;
    HeadlessInAppWebView? headlessWebView;
    StoryExtractionResult? apiHit;
    var navigatedToStory = false;

    void finish(StoryExtractionResult? result) {
      if (!completer.isCompleted) completer.complete(result);
    }

    StoryExtractionResult? parseReelsPayload(dynamic data) {
      if (data == null) return null;
      try {
        final root = data is String ? jsonDecode(data) : data;
        if (root is! Map) return null;

        final items = <Map<String, dynamic>>[];

        void collectItems(dynamic node) {
          if (node is Map) {
            final map = Map<String, dynamic>.from(node);
            if ((map['pk'] != null || map['id'] != null) &&
                (map['image_versions2'] != null ||
                    map['video_versions'] != null)) {
              items.add(map);
            }
            for (final value in map.values) {
              collectItems(value);
            }
          } else if (node is List) {
            for (final value in node) {
              collectItems(value);
            }
          }
        }

        collectItems(root);

        Map<String, dynamic>? match;
        if (mediaId != null) {
          for (final item in items) {
            final pk = '${item['pk'] ?? ''}';
            final id = '${item['id'] ?? ''}';
            if (pk == mediaId ||
                id == mediaId ||
                id.startsWith(mediaId) ||
                id.contains(mediaId)) {
              match = item;
              break;
            }
          }
        }
        match ??= items.isNotEmpty ? items.first : null;
        if (match == null) return null;

        final versions = match['video_versions'];
        if (versions is List && versions.isNotEmpty) {
          String? bestUrl;
          var bestArea = -1;
          for (final v in versions) {
            if (v is! Map) continue;
            final url = v['url']?.toString();
            if (url == null || url.isEmpty) continue;
            final w = (v['width'] as num?)?.toInt() ?? 0;
            final h = (v['height'] as num?)?.toInt() ?? 0;
            final area = w * h;
            if (area >= bestArea) {
              bestArea = area;
              bestUrl = url;
            }
          }
          if (bestUrl != null) {
            return StoryExtractionResult(
              mediaUrl: bestUrl,
              thumbnailUrl: _bestCandidateUrl(match['image_versions2']),
              mediaType: 'video',
            );
          }
        }

        final imageUrl = _bestCandidateUrl(match['image_versions2']);
        if (imageUrl != null) {
          return StoryExtractionResult(
            mediaUrl: imageUrl,
            mediaType: 'image',
          );
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[Story] parse error: $e');
      }
      return null;
    }

    Future<void> tryApiExtract(InAppWebViewController controller) async {
      if (username == null || mediaId == null || completer.isCompleted) return;
      try {
        final js = '''
          (async function() {
            const username = ${jsonEncode(username)};
            const mediaId = ${jsonEncode(mediaId)};
            const appId = '$_igAppId';
            const headers = {
              'X-IG-App-ID': appId,
              'Accept': '*/*',
              'X-Requested-With': 'XMLHttpRequest'
            };
            try {
              const profileRes = await fetch(
                'https://www.instagram.com/api/v1/users/web_profile_info/?username=' +
                  encodeURIComponent(username),
                { credentials: 'include', headers: headers }
              );
              if (profileRes.status === 401 || profileRes.status === 403) {
                return JSON.stringify({ requiresLogin: true });
              }
              const profile = await profileRes.json();
              const userId = profile && profile.data && profile.data.user
                ? profile.data.user.id
                : null;
              if (!userId) return JSON.stringify({ error: 'no_user' });

              const reelsRes = await fetch(
                'https://www.instagram.com/api/v1/feed/reels_media/?reel_ids=' +
                  encodeURIComponent(userId),
                { credentials: 'include', headers: headers }
              );
              if (reelsRes.status === 401 || reelsRes.status === 403) {
                return JSON.stringify({ requiresLogin: true });
              }
              const reels = await reelsRes.json();
              return JSON.stringify({ ok: true, mediaId: mediaId, payload: reels });
            } catch (e) {
              return JSON.stringify({ error: String(e) });
            }
          })();
        ''';
        final apiRaw = await controller.evaluateJavascript(source: js);
        if (apiRaw == null || apiRaw.toString() == 'null') return;

        final decoded = jsonDecode(apiRaw.toString());
        if (decoded is! Map) return;

        if (decoded['requiresLogin'] == true) {
          finish(
            const StoryExtractionResult(
              mediaType: 'unknown',
              requiresLogin: true,
            ),
          );
          return;
        }

        if (decoded['ok'] == true && decoded['payload'] != null) {
          final hit = parseReelsPayload(decoded['payload']);
          if (hit != null) {
            apiHit = hit;
            finish(hit);
          }
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[Story] API extract error: $e');
      }
    }

    headlessWebView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri('https://www.instagram.com/'),
        headers: const {'User-Agent': InstagramCdnUtils.mobileUserAgent},
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        sharedCookiesEnabled: true,
        thirdPartyCookiesEnabled: true,
        useOnLoadResource: true,
        useShouldInterceptRequest: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        userAgent: InstagramCdnUtils.mobileUserAgent,
      ),
      onWebViewCreated: (controller) {
        controller.addJavaScriptHandler(
          handlerName: 'onStoryApi',
          callback: (args) {
            if (args.isEmpty || completer.isCompleted) return null;
            final raw = args.first?.toString();
            if (raw == null || raw.isEmpty) return null;
            final parsedResult = parseReelsPayload(raw);
            if (parsedResult != null) {
              apiHit = parsedResult;
              finish(parsedResult);
            }
            return null;
          },
        );
      },
      shouldInterceptRequest: (controller, request) async {
        final url = request.url.toString();
        if (_isLoginUrl(url) && !completer.isCompleted) {
          finish(
            const StoryExtractionResult(
              mediaType: 'unknown',
              requiresLogin: true,
            ),
          );
        }
        return null;
      },
      onLoadStop: (controller, url) async {
        if (completer.isCompleted) return;
        final current = url?.toString() ?? '';
        if (_isLoginUrl(current)) {
          finish(
            const StoryExtractionResult(
              mediaType: 'unknown',
              requiresLogin: true,
            ),
          );
          return;
        }

        try {
          await controller.evaluateJavascript(source: '''
            (function() {
              if (window.__storyHookInstalled) return;
              window.__storyHookInstalled = true;
              function maybeSend(text) {
                try {
                  if (!text || text.length < 40) return;
                  if (text.indexOf('video_versions') === -1 &&
                      text.indexOf('image_versions2') === -1) return;
                  window.flutter_inappwebview.callHandler('onStoryApi', text);
                } catch (e) {}
              }
              const origFetch = window.fetch;
              window.fetch = function() {
                return origFetch.apply(this, arguments).then(function(res) {
                  try { res.clone().text().then(maybeSend); } catch (e) {}
                  return res;
                });
              };
            })();
          ''');
        } catch (_) {}

        // First load of instagram.com home → run API extract.
        if (!navigatedToStory) {
          await tryApiExtract(controller);
          if (completer.isCompleted) return;

          navigatedToStory = true;
          try {
            await controller.loadUrl(
              urlRequest: URLRequest(
                url: WebUri(storyUrl),
                headers: const {
                  'User-Agent': InstagramCdnUtils.mobileUserAgent,
                },
              ),
            );
          } catch (_) {}
          return;
        }

        // Second load (story page) — wait for network + DOM fallback.
        await Future<void>.delayed(const Duration(milliseconds: 3500));
        if (completer.isCompleted) return;

        await tryApiExtract(controller);
        if (completer.isCompleted) return;

        try {
          final jsResult = await controller.evaluateJavascript(source: '''
            (function() {
              const video = document.querySelector('video');
              if (video) {
                let src = video.currentSrc || video.src || '';
                if (!src) {
                  const s = video.querySelector('source');
                  if (s) src = s.src || '';
                }
                if (src && (src.indexOf('cdninstagram') !== -1 || src.indexOf('fbcdn') !== -1)) {
                  return JSON.stringify({
                    type: 'video',
                    url: src,
                    poster: video.poster || ''
                  });
                }
              }
              const imgs = Array.from(document.querySelectorAll('img'))
                .map(function(img) {
                  const s = img.currentSrc || img.src || '';
                  const w = img.naturalWidth || 0;
                  const h = img.naturalHeight || 0;
                  return { url: s, area: w * h };
                })
                .filter(function(i) {
                  return i.url &&
                    (i.url.indexOf('cdninstagram') !== -1 || i.url.indexOf('fbcdn') !== -1) &&
                    i.url.indexOf('profile_pic') === -1 &&
                    i.area > 250000;
                })
                .sort(function(a, b) { return b.area - a.area; });
              if (imgs.length > 0) {
                return JSON.stringify({ type: 'image', url: imgs[0].url });
              }
              return null;
            })()
          ''');

          if (jsResult != null && jsResult.toString() != 'null') {
            final map = jsonDecode(jsResult.toString());
            if (map is Map) {
              final mediaUrl = map['url'] as String?;
              if (map['type'] == 'video' && mediaUrl != null) {
                finish(
                  StoryExtractionResult(
                    mediaUrl: mediaUrl,
                    thumbnailUrl: map['poster'] as String?,
                    mediaType: 'video',
                  ),
                );
                return;
              }
              if (map['type'] == 'image' && mediaUrl != null) {
                finish(
                  StoryExtractionResult(
                    mediaUrl: mediaUrl,
                    mediaType: 'image',
                  ),
                );
                return;
              }
            }
          }
        } catch (e) {
          if (kDebugMode) debugPrint('[Story] DOM fallback error: $e');
        }

        finish(apiHit);
      },
    );

    timeoutTimer = Timer(_timeout, () {
      if (kDebugMode) debugPrint('[Story] Timeout');
      finish(apiHit);
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

  static String? _bestCandidateUrl(dynamic imageVersions2) {
    if (imageVersions2 is! Map) return null;
    final candidates = imageVersions2['candidates'];
    if (candidates is! List || candidates.isEmpty) return null;
    String? bestUrl;
    var bestArea = -1;
    for (final c in candidates) {
      if (c is! Map) continue;
      final url = c['url']?.toString();
      if (url == null || url.isEmpty) continue;
      final w = (c['width'] as num?)?.toInt() ?? 0;
      final h = (c['height'] as num?)?.toInt() ?? 0;
      final area = w * h;
      if (area >= bestArea) {
        bestArea = area;
        bestUrl = url;
      }
    }
    return bestUrl;
  }
}
