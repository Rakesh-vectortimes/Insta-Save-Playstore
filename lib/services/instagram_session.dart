import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Shared Instagram WebView session (from Open Instagram browser).
class InstagramSession {
  InstagramSession._();

  static Future<String?> getSessionId() async {
    try {
      for (final host in [
        'https://www.instagram.com',
        'https://instagram.com',
        'https://i.instagram.com',
      ]) {
        final cookies = await CookieManager.instance().getCookies(
          url: WebUri(host),
        );
        for (final c in cookies) {
          if (c.name == 'sessionid' && (c.value?.isNotEmpty ?? false)) {
            return c.value;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<bool> hasSession() async {
    final id = await getSessionId();
    if (id != null && id.isNotEmpty) return true;
    // Some WebView builds expose ds_user_id before sessionid is readable.
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri('https://www.instagram.com'),
      );
      for (final c in cookies) {
        if (c.name == 'ds_user_id' && (c.value?.isNotEmpty ?? false)) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// Cookie header for native Instagram API calls from the app.
  static Future<String?> cookieHeader() async {
    try {
      final all = <String, String>{};
      for (final host in [
        'https://www.instagram.com',
        'https://instagram.com',
        'https://i.instagram.com',
      ]) {
        final cookies = await CookieManager.instance().getCookies(
          url: WebUri(host),
        );
        for (final c in cookies) {
          if (c.value?.isNotEmpty ?? false) {
            all[c.name] = c.value!;
          }
        }
      }
      if (all.isEmpty) return null;
      return all.entries.map((e) => '${e.key}=${e.value}').join('; ');
    } catch (_) {
      return null;
    }
  }

  /// Headers for our backend when it supports session-based HD DP.
  static Future<Map<String, String>> apiSessionHeaders() async {
    final id = await getSessionId();
    if (id == null || id.isEmpty) return const {};
    return {'x-instagram-session': id};
  }
}
