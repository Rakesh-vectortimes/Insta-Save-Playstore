import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'instagram_cdn_utils.dart';
import 'instagram_session.dart';

class DpExtractionResult {
  const DpExtractionResult({
    this.dpUrl,
    this.username,
    this.fullName,
    required this.isHd,
    required this.source,
    this.width,
    this.height,
  });

  final String? dpUrl;
  final String? username;
  final String? fullName;
  final bool isHd;
  final String source;
  final int? width;
  final int? height;
}

class InstagramDpWebViewService {
  static const Duration _timeout = Duration(seconds: 20);
  static const _igAppId = '936619743392459';
  static const int _hdMinEdge = 640;

  /// Instagram's web-facing profile endpoint caps the "hd" profile picture
  /// at a modest size (often ~320px) even for a logged-in session — the
  /// SAME account can show a genuinely sharp, full-resolution picture in
  /// the real Instagram app's own "view photo" viewer. Presenting as the
  /// native Android app on the same request often unlocks that real
  /// hd_profile_pic_url_info instead of the web-capped one. A browser's
  /// fetch() can't override User-Agent (it's a forbidden header), so this
  /// only works via a raw HTTP request, never from inside the WebView page.
  static const _appUserAgent =
      'Instagram 309.0.0.41.113 Android (33/13; 420dpi; 1080x2400; '
      'samsung; SM-G991B; o1s; exynos2100; en_US; 550821585)';

  static Future<String?> getStoredSessionId() => InstagramSession.getSessionId();

  /// Prefer native HTTP with WebView cookies (session HD), then WebView fallback.
  static Future<DpExtractionResult?> extractDp(String username) async {
    final clean = username.replaceAll('@', '').trim();
    if (clean.isEmpty) return null;

    // 1) Native request with full Instagram cookie jar (best HD path).
    final native = await _fetchViaNativeApi(clean);
    if (native != null && native.isHd) {
      if (kDebugMode) {
        debugPrint(
          '[DP] native HD ${native.width}x${native.height} source=${native.source}',
        );
      }
      return native;
    }

    // 1b) Same account, same endpoint shape, but posing as the native app —
    // often returns the real, uncapped HD picture the web UA never gets.
    final appApi = await _fetchViaAppApi(clean);
    if (appApi != null && appApi.isHd) {
      if (kDebugMode) {
        debugPrint(
          '[DP] app-UA HD ${appApi.width}x${appApi.height} source=${appApi.source}',
        );
      }
      return appApi;
    }

    // 2) WebView session fetch
    final web = await _fetchViaWebView(clean);
    final best = _pickBetter(_pickBetter(native, appApi), web);
    if (best == null) return null;

    // 3) Try upgrading CDN size tokens if still low-res (may 403 — keep lowQuality).
    if (!best.isHd && best.dpUrl != null) {
      final upgraded = _upgradeCdnUrl(best.dpUrl!);
      if (upgraded != null && upgraded != best.dpUrl) {
        return DpExtractionResult(
          dpUrl: upgraded,
          username: best.username,
          fullName: best.fullName,
          isHd: false,
          width: best.width,
          height: best.height,
          source: 'cdn_upgraded_attempt',
        );
      }
    }
    return best;
  }

  static DpExtractionResult? _pickBetter(
    DpExtractionResult? a,
    DpExtractionResult? b,
  ) {
    if (a == null) return b;
    if (b == null) return a;
    final ae = a.width ?? 0;
    final be = b.width ?? 0;
    return be > ae ? b : a;
  }

  static Future<DpExtractionResult?> _fetchViaNativeApi(String username) async {
    try {
      final cookie = await InstagramSession.cookieHeader();
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 12),
          headers: {
            'User-Agent': InstagramCdnUtils.mobileUserAgent,
            'Accept': '*/*',
            'Accept-Language': 'en-US,en;q=0.9',
            'X-IG-App-ID': _igAppId,
            'X-Requested-With': 'XMLHttpRequest',
            'Referer': 'https://www.instagram.com/',
            if (cookie != null && cookie.isNotEmpty) 'Cookie': cookie,
          },
          responseType: ResponseType.json,
          validateStatus: (s) => s != null && s < 500,
        ),
      );

      final response = await dio.get<Map<String, dynamic>>(
        'https://www.instagram.com/api/v1/users/web_profile_info/',
        queryParameters: {'username': username},
      );

      if (response.statusCode != 200 || response.data == null) {
        if (kDebugMode) {
          debugPrint('[DP] native HTTP ${response.statusCode}');
        }
        return null;
      }

      final user = response.data?['data']?['user'];
      if (user is! Map) return null;
      return _fromUserMap(Map<String, dynamic>.from(user), username);
    } catch (e) {
      if (kDebugMode) debugPrint('[DP] native API error: $e');
      return null;
    }
  }

  /// Same request shape as [_fetchViaNativeApi], posing as the native
  /// Android app (User-Agent + i.instagram.com host) instead of a mobile
  /// browser. Purely additive — on any failure this just contributes
  /// nothing and the existing web-UA / WebView results are used as before.
  static Future<DpExtractionResult?> _fetchViaAppApi(String username) async {
    try {
      final cookie = await InstagramSession.cookieHeader();
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 12),
          receiveTimeout: const Duration(seconds: 12),
          headers: {
            'User-Agent': _appUserAgent,
            'Accept': '*/*',
            'Accept-Language': 'en-US,en;q=0.9',
            'X-IG-App-ID': _igAppId,
            'X-Requested-With': 'XMLHttpRequest',
            'Referer': 'https://www.instagram.com/',
            if (cookie != null && cookie.isNotEmpty) 'Cookie': cookie,
          },
          responseType: ResponseType.json,
          validateStatus: (s) => s != null && s < 500,
        ),
      );

      final response = await dio.get<Map<String, dynamic>>(
        'https://i.instagram.com/api/v1/users/web_profile_info/',
        queryParameters: {'username': username},
      );

      if (response.statusCode != 200 || response.data == null) {
        if (kDebugMode) {
          debugPrint('[DP] app-UA HTTP ${response.statusCode}');
        }
        return null;
      }

      final user = response.data?['data']?['user'];
      if (user is! Map) return null;
      return _fromUserMap(Map<String, dynamic>.from(user), username);
    } catch (e) {
      if (kDebugMode) debugPrint('[DP] app-UA API error: $e');
      return null;
    }
  }

  static DpExtractionResult? _fromUserMap(
    Map<String, dynamic> user,
    String fallbackUsername,
  ) {
    String? bestUrl;
    var bestW = 0;
    var bestH = 0;
    var source = 'webview_standard';

    void consider(String? url, int w, int h, String src) {
      if (url == null || url.isEmpty) return;
      final edge = w > 0 && h > 0 ? (w < h ? w : h) : _edgeFromUrl(url);
      final bestEdge = bestW > 0 && bestH > 0
          ? (bestW < bestH ? bestW : bestH)
          : 0;
      if (edge >= bestEdge) {
        bestUrl = url;
        bestW = w > 0 ? w : edge;
        bestH = h > 0 ? h : edge;
        source = src;
      }
    }

    final hdInfo = user['hd_profile_pic_url_info'];
    if (hdInfo is Map) {
      consider(
        hdInfo['url']?.toString(),
        (hdInfo['width'] as num?)?.toInt() ?? 0,
        (hdInfo['height'] as num?)?.toInt() ?? 0,
        'session_hd',
      );
    }

    final versions = user['hd_profile_pic_versions'];
    if (versions is List) {
      for (final v in versions) {
        if (v is! Map) continue;
        consider(
          v['url']?.toString(),
          (v['width'] as num?)?.toInt() ?? 0,
          (v['height'] as num?)?.toInt() ?? 0,
          'session_hd',
        );
      }
    }

    // No explicit width/height on this field — let consider() derive the
    // real edge from the CDN URL's own size token instead of assuming a
    // fixed 720px (many accounts' actual HD picture is well below that,
    // which previously made the app claim "HD" for a mediocre image).
    consider(
      user['profile_pic_url_hd']?.toString(),
      0,
      0,
      'session_hd',
    );

    // Last resort tiny thumb
    if (bestUrl == null) {
      consider(user['profile_pic_url']?.toString(), 150, 150, 'thumb');
    }

    if (bestUrl == null) return null;

    // Always try CDN upgrade if still small — but do NOT claim HD until verified.
    var finalUrl = bestUrl!;
    var edge = bestW < bestH ? bestW : bestH;
    if (edge < _hdMinEdge) {
      final upgraded = _upgradeCdnUrl(finalUrl);
      if (upgraded != null) {
        finalUrl = upgraded;
        source = 'cdn_upgraded_attempt';
      }
    }

    return DpExtractionResult(
      dpUrl: finalUrl,
      username: user['username']?.toString() ?? fallbackUsername,
      fullName: user['full_name']?.toString(),
      isHd: edge >= _hdMinEdge,
      width: bestW,
      height: bestH,
      source: source,
    );
  }

  /// Strip / raise Instagram `stp=...s150x150` so CDN may return full image.
  static String? _upgradeCdnUrl(String url) {
    try {
      final uri = Uri.parse(url);
      if (!InstagramCdnUtils.isInstagramCdn(url)) return null;

      final params = Map<String, String>.from(uri.queryParameters);
      var changed = false;

      if (params.containsKey('stp')) {
        final stp = params['stp']!;
        if (RegExp(r's\d{2,4}x\d{2,4}').hasMatch(stp)) {
          params['stp'] = stp.replaceAllMapped(
            RegExp(r's\d{2,4}x\d{2,4}'),
            (_) => 's1080x1080',
          );
          changed = true;
        }
      }

      var path = uri.path;
      if (RegExp(r'/\d{2,4}x\d{2,4}/').hasMatch(path)) {
        path = path.replaceAll(RegExp(r'/\d{2,4}x\d{2,4}/'), '/');
        changed = true;
      }

      if (!changed && url.toLowerCase().contains('s150x150')) {
        return url
            .replaceAll('s150x150', 's1080x1080')
            .replaceAll('S150x150', 's1080x1080');
      }

      if (!changed) {
        // Remove stp entirely — often returns original.
        if (params.containsKey('stp')) {
          params.remove('stp');
          changed = true;
        }
      }

      if (!changed) return null;
      return uri.replace(path: path, queryParameters: params).toString();
    } catch (_) {
      return null;
    }
  }

  static Future<DpExtractionResult?> _fetchViaWebView(String username) async {
    final hasSession = await InstagramSession.hasSession();
    final completer = Completer<DpExtractionResult?>();
    Timer? timeoutTimer;
    HeadlessInAppWebView? headlessWebView;

    void finish(DpExtractionResult? result) {
      if (!completer.isCompleted) completer.complete(result);
    }

    headlessWebView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri('https://www.instagram.com/'),
        headers: const {'User-Agent': InstagramCdnUtils.mobileUserAgent},
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        sharedCookiesEnabled: true,
        thirdPartyCookiesEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        useShouldOverrideUrlLoading: true,
        userAgent: InstagramCdnUtils.mobileUserAgent,
      ),
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final scheme =
            (navigationAction.request.url?.scheme ?? '').toLowerCase();
        if (scheme == 'http' || scheme == 'https') {
          return NavigationActionPolicy.ALLOW;
        }
        return NavigationActionPolicy.CANCEL;
      },
      onLoadStop: (controller, url) async {
        if (completer.isCompleted) return;
        try {
          final result = await controller.callAsyncJavaScript(
            functionBody: '''
              const username = ${jsonEncode(username)};
              const headers = {
                'X-IG-App-ID': '$_igAppId',
                'Accept': '*/*',
                'X-Requested-With': 'XMLHttpRequest'
              };
              try {
                const res = await fetch(
                  'https://www.instagram.com/api/v1/users/web_profile_info/?username=' +
                    encodeURIComponent(username),
                  { credentials: 'include', headers: headers }
                );
                if (!res.ok) return { error: 'http_' + res.status };
                const json = await res.json();
                return { ok: true, user: json && json.data && json.data.user };
              } catch (e) {
                return { error: String(e) };
              }
            ''',
          );
          final decoded = result?.value;
          if (decoded is Map &&
              decoded['ok'] == true &&
              decoded['user'] is Map) {
            final parsed = _fromUserMap(
              Map<String, dynamic>.from(
                (decoded['user'] as Map).map(
                  (k, v) => MapEntry(k.toString(), v),
                ),
              ),
              username,
            );
            if (parsed != null) {
              finish(
                DpExtractionResult(
                  dpUrl: parsed.dpUrl,
                  username: parsed.username,
                  fullName: parsed.fullName,
                  isHd: parsed.isHd,
                  width: parsed.width,
                  height: parsed.height,
                  source: parsed.isHd
                      ? (hasSession ? 'session_hd' : parsed.source)
                      : parsed.source,
                ),
              );
              return;
            }
          }
        } catch (e) {
          if (kDebugMode) debugPrint('[DP] webview extract: $e');
        }
        // Leave completer open — timeout finishes null if this load failed.
      },
      onReceivedError: (controller, request, error) {
        if (request.isForMainFrame == true) finish(null);
      },
    );

    timeoutTimer = Timer(_timeout, () => finish(null));

    try {
      await headlessWebView.run();
      return await completer.future;
    } catch (e) {
      if (kDebugMode) debugPrint('[DP] WebView start failed: $e');
      return null;
    } finally {
      timeoutTimer.cancel();
      try {
        await headlessWebView.dispose();
      } catch (_) {}
    }
  }

  static int _edgeFromUrl(String url) {
    final lower = url.toLowerCase();
    final match = RegExp(r's(\d{2,4})x(\d{2,4})').firstMatch(lower);
    if (match != null) {
      final a = int.tryParse(match.group(1)!) ?? 0;
      final b = int.tryParse(match.group(2)!) ?? 0;
      return a < b ? a : b;
    }
    if (lower.contains('150x150')) return 150;
    if (lower.contains('320x320')) return 320;
    if (lower.contains('640x640')) return 640;
    if (lower.contains('1080x1080')) return 1080;
    return 200;
  }
}
