import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../models/download_item.dart';
import '../models/story_tray_item.dart';
import '../services/download_history_service.dart';
import '../services/download_service.dart';
import '../services/instagram_cdn_utils.dart';
import '../services/instagram_session.dart';
import '../widgets/download_progress_dialog.dart';
import 'privacy_policy_screen.dart';

/// Instagram in-app browser for stories (InSaver-style):
/// first-time login explainer → browse → pink FAB → multi-select download.
class InstagramBrowserScreen extends ConsumerStatefulWidget {
  const InstagramBrowserScreen({
    super.key,
    this.initialUrl = 'https://www.instagram.com/',
  });

  final String initialUrl;

  @override
  ConsumerState<InstagramBrowserScreen> createState() =>
      _InstagramBrowserScreenState();
}

class _InstagramBrowserScreenState
    extends ConsumerState<InstagramBrowserScreen> {
  static const _prefsWhyLoginKey = 'story_why_login_shown_v1';
  static const _igAppId = '936619743392459';

  InAppWebViewController? _controller;
  final _downloadService = DownloadService();
  final _urlController = TextEditingController();

  /// CDN media URLs seen while browsing stories (network + JS hooks).
  final List<String> _capturedStoryUrls = [];
  Map<String, dynamic>? _capturedTrayPayload;

  String? _pageUrl;
  var _loading = true;
  var _canGoBack = false;
  var _loggedIn = false;
  var _showTipBanner = true;
  var _onStoryPage = false;
  var _fetchingTray = false;

  /// Last tray-fetch diagnostic (always logged; shown in snackbar on fallback).
  String? _lastTrayDebug;

  /// Avoid re-hitting web_profile_info on every pink-FAB tap (IG 429s quickly).
  final Map<String, String> _userIdCache = {};

  /// Last username we built a tray for — used to drop stale captures on swipe.
  String? _lastFetchedUsername;

  /// True when this screen was opened directly with a story link (e.g. pasted
  /// on the home screen and routed here) rather than reached by browsing.
  /// Used to auto-open the download sheet instead of leaving the user staring
  /// at the raw Instagram page waiting for a manual tap on the download FAB.
  bool _autoDownloadAttempted = false;
  late final bool _isDirectStoryLink = RegExp(
    r'instagram\.com/stories/',
    caseSensitive: false,
  ).hasMatch(widget.initialUrl);

  static const _nonUserPaths = {
    'notifications',
    'explore',
    'direct',
    'accounts',
    'reels',
    'reel',
    'p',
    'stories',
    'highlights',
    'inbox',
    'liked',
    'tagged',
    'saved',
    'shop',
    'live',
    'tv',
    'guide',
    'guides',
  };

  String get _startUrl {
    final raw = widget.initialUrl.trim();
    if (raw.isEmpty) return 'https://www.instagram.com/';
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    return 'https://$raw';
  }

  @override
  void initState() {
    super.initState();
    _urlController.text = _startUrl;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _refreshSessionFlag();
      await _maybeShowWhyLogin();
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _refreshSessionFlag() async {
    final has = await InstagramSession.hasSession();
    if (mounted) setState(() => _loggedIn = has);
  }

  Future<void> _maybeShowWhyLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final shown = prefs.getBool(_prefsWhyLoginKey) ?? false;
    if (shown || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _WhyLoginDialog(
        onGotIt: () async {
          await prefs.setBool(_prefsWhyLoginKey, true);
          if (ctx.mounted) Navigator.pop(ctx);
        },
        onPrivacy: () {
          Navigator.pop(ctx);
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen()),
          );
        },
      ),
    );
  }

  void _syncPageFlags(String? url) {
    final u = url ?? '';
    final urlSaysStory = RegExp(
      r'instagram\.com/stories/',
      caseSensitive: false,
    ).hasMatch(u);
    final prevUrl = _pageUrl;
    setState(() {
      _pageUrl = u;
      // Instagram SPA often keeps https://www.instagram.com/ while a story is open.
      // Never force _onStoryPage=false from the URL alone.
      if (urlSaysStory) _onStoryPage = true;
      if (u.isNotEmpty) _urlController.text = u;
    });
    if (urlSaysStory) {
      final prevUser = _usernameFromStoryUrl(prevUrl);
      final nextUser = _usernameFromStoryUrl(u);
      if (prevUser != null && nextUser != null && prevUser != nextUser) {
        // Only drop CDN URL harvest — keep __qsStoryPayload; match-guards
        // reject wrong-user trays, and IG may already have fetched the new one.
        _capturedStoryUrls.clear();
      }
    }
  }

  /// Instagram often hides `/stories/` in the address bar — detect viewer UI.
  Future<void> _refreshStoryUiFlag(InAppWebViewController controller) async {
    try {
      final result = await controller.callAsyncJavaScript(functionBody: r'''
        try {
          var href = location.href || '';
          if (/instagram\.com\/stories\//i.test(href)) return true;
          var text = (document.body && document.body.innerText) || '';
          if (text.indexOf("story before it disappears") >= 0) return false;
          if (text.indexOf('Watch Full Reel') >= 0) return true;
          // Image or video story viewer: large media + story header chrome
          var videos = document.querySelectorAll('video');
          for (var i = 0; i < videos.length; i++) {
            var vr = videos[i].getBoundingClientRect();
            if (vr.width > 140 && vr.height > 160) return true;
          }
          var imgs = document.querySelectorAll('img');
          var big = 0;
          for (var j = 0; j < imgs.length; j++) {
            var r = imgs[j].getBoundingClientRect();
            if (r.width * r.height > 60000) big++;
          }
          if (big >= 1 && (text.indexOf('h') >= 0 || text.indexOf('m') >= 0)) {
            // "18 h" / "5 m" style timestamps are common on stories
            if (/\b\d+\s*[hm]\b/i.test(text) || text.indexOf('Send message') >= 0) return true;
          }
        } catch (e) {}
        return false;
      ''');
      final onStory = result?.value == true;
      if (mounted && onStory != _onStoryPage) {
        if (!onStory && _onStoryPage) _clearStoryCaptures();
        setState(() => _onStoryPage = onStory);
      } else if (mounted && onStory && !_onStoryPage) {
        setState(() => _onStoryPage = true);
      }
    } catch (_) {}
  }

  Future<void> _loadWebLogin(InAppWebViewController controller) async {
    final next = (_pageUrl != null && _pageUrl!.startsWith('http'))
        ? _pageUrl!
        : 'https://www.instagram.com/';
    final login = Uri.https(
      'www.instagram.com',
      '/accounts/login/',
      {'next': next},
    );
    await controller.loadUrl(
      urlRequest: URLRequest(url: WebUri(login.toString())),
    );
  }

  /// Instagram's story gate button opens the native app. Rewire it to web login.
  Future<void> _hijackOpenInstagramButtons(
    InAppWebViewController controller,
  ) async {
    try {
      await controller.evaluateJavascript(source: r'''
(function () {
  if (window.__qsOpenIgHijack) return;
  window.__qsOpenIgHijack = true;
  function goLogin(e) {
    try {
      if (e) { e.preventDefault(); e.stopPropagation(); }
    } catch (_) {}
    var next = encodeURIComponent(location.href);
    location.href = 'https://www.instagram.com/accounts/login/?next=' + next;
    return false;
  }
  function patch() {
    var nodes = document.querySelectorAll('a, button, div[role="button"], span');
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (el.__qsPatched) continue;
      var t = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim().toLowerCase();
      if (t === 'open instagram' || t.indexOf('open in app') === 0) {
        el.__qsPatched = true;
        el.addEventListener('click', goLogin, true);
        if (el.tagName === 'A') {
          el.setAttribute('href', 'https://www.instagram.com/accounts/login/?next=' + encodeURIComponent(location.href));
        }
      }
    }
  }
  patch();
  setTimeout(patch, 800);
  setTimeout(patch, 2000);
})();
''');
    } catch (e) {
      if (kDebugMode) debugPrint('[Browser] hijack Open Instagram failed: $e');
    }
  }

  Future<void> _updateNav() async {
    final c = _controller;
    if (c == null) return;
    final canBack = await c.canGoBack();
    if (mounted) setState(() => _canGoBack = canBack);
  }

  Future<void> _reload() async {
    await _controller?.reload();
  }

  Future<void> _goHome() async {
    await _controller?.loadUrl(
      urlRequest: URLRequest(url: WebUri('https://www.instagram.com/')),
    );
  }

  String? _usernameFromStoryUrl(String? url) {
    if (url == null) return null;
    return RegExp(
      r'instagram\.com/stories/([A-Za-z0-9._]+)',
      caseSensitive: false,
    ).firstMatch(url)?.group(1);
  }

  void _rememberStoryUrl(String url, {bool force = false}) {
    // Only keep media while a story viewer is open — avoids feed pollution.
    if (!force && !_onStoryPage) return;
    if (!_looksLikeStoryMediaUrl(url)) return;
    _capturedStoryUrls.remove(url);
    _capturedStoryUrls.add(url);
    if (_capturedStoryUrls.length > 40) {
      _capturedStoryUrls.removeRange(0, _capturedStoryUrls.length - 40);
    }
  }

  void _clearStoryCaptures() {
    _capturedStoryUrls.clear();
    _capturedTrayPayload = null;
    // Also drop the JS-side passive capture so the next story can't reuse it.
    final c = _controller;
    if (c != null) {
      c.evaluateJavascript(source: r'''
        try {
          window.__qsStoryPayload = null;
          window.__qsStoryMedia = [];
        } catch (e) {}
      ''');
    }
  }

  bool _isStoryApiPayload(Map data) {
    if (data.containsKey('reels_media') ||
        data.containsKey('reels') ||
        data['reel'] is Map) {
      return true;
    }
    if (data['items'] is List &&
        data.containsKey('user') &&
        (data.containsKey('expiring_at') ||
            data.containsKey('latest_reel_media'))) {
      return true;
    }
    // GraphQL: { data, extensions } with story nodes nested under query fields.
    return _deepHasStoryItem(data, 0);
  }

  bool _deepHasStoryItem(dynamic node, int depth) {
    if (node == null || depth > 8) return false;
    if (node is List) {
      for (final n in node) {
        if (_deepHasStoryItem(n, depth + 1)) return true;
      }
      return false;
    }
    if (node is Map) {
      final hasMedia =
          node['image_versions2'] != null || node['video_versions'] != null;
      final hasExpiry =
          node['expiring_at'] != null || node['taken_at'] != null;
      if (hasMedia && hasExpiry) return true;
      for (final v in node.values) {
        if (_deepHasStoryItem(v, depth + 1)) return true;
      }
    }
    return false;
  }

  String? _deepFindUsername(dynamic node, [int depth = 0]) {
    if (node == null || depth > 8) return null;
    if (node is List) {
      for (final n in node) {
        final r = _deepFindUsername(n, depth + 1);
        if (r != null) return r;
      }
      return null;
    }
    if (node is Map) {
      final user = node['user'];
      if (user is Map) {
        final name = user['username']?.toString();
        if (name != null && name.isNotEmpty) return name;
      }
      for (final v in node.values) {
        final r = _deepFindUsername(v, depth + 1);
        if (r != null) return r;
      }
    }
    return null;
  }

  bool _payloadMatchesUsername(Map payload, String username) {
    final target = username.toLowerCase();
    final found = _deepFindUsername(payload);
    if (found != null && found.toLowerCase() == target) return true;

    // Also accept if any deep story item's user matches (multi-node trays).
    return _deepUsernameAnywhere(payload, target, 0);
  }

  bool _deepUsernameAnywhere(dynamic node, String targetLower, int depth) {
    if (node == null || depth > 8) return false;
    if (node is List) {
      for (final n in node) {
        if (_deepUsernameAnywhere(n, targetLower, depth + 1)) return true;
      }
      return false;
    }
    if (node is Map) {
      final user = node['user'];
      if (user is Map) {
        final name = user['username']?.toString();
        if (name != null && name.toLowerCase() == targetLower) return true;
      }
      for (final v in node.values) {
        if (_deepUsernameAnywhere(v, targetLower, depth + 1)) return true;
      }
    }
    return false;
  }

  /// Pull `window.__qsStoryPayload` into Dart if the JS hook saw story traffic
  /// but the bridge handler hadn't run yet (or payload arrived after last sync).
  Future<void> _syncCapturedPayloadFromWebView() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final result = await controller.callAsyncJavaScript(functionBody: r'''
        try {
          var p = window.__qsStoryPayload;
          if (!p) return null;
          if (typeof p === 'string') return p;
          return JSON.stringify(p);
        } catch (e) { return null; }
      ''');
      final raw = result?.value?.toString();
      if (raw == null || raw.length < 40 || raw == 'null') return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final map = Map<String, dynamic>.from(
        decoded.map((k, v) => MapEntry(k.toString(), v)),
      );
      if (_isStoryApiPayload(map)) {
        // Don't clobber a good capture with unrelated feed/story traffic.
        _capturedTrayPayload = map;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Browser] sync captured payload failed: $e');
    }
  }

  StoryTrayResult? _trayFromCapturedPayload(String username) {
    final payload = _capturedTrayPayload;
    if (payload == null || !_isStoryApiPayload(payload)) return null;
    if (!_payloadMatchesUsername(payload, username)) {
      print(
        '[Browser] ignoring stale cache (wanted=$username, payload user mismatch)',
      );
      return null;
    }
    final items = _parseTrayItems(payload, forUsername: username);
    if (items.isEmpty) return null;
    return StoryTrayResult(username: username, items: items);
  }

  void _cacheUserIdFromPayload(String username, Map? payload) {
    if (payload == null) return;
    final id = _userIdFromStoryPayload(payload, username);
    if (id != null && id.isNotEmpty) {
      _userIdCache[username] = id;
    }
  }

  String? _userIdFromStoryPayload(Map data, String username) {
    String? fromUser(dynamic user) {
      if (user is! Map) return null;
      final id = user['id']?.toString() ?? user['pk']?.toString();
      if (id != null && RegExp(r'^\d{5,}$').hasMatch(id)) return id;
      return null;
    }

    String? deep(dynamic node, int depth) {
      if (node == null || depth > 8) return null;
      if (node is List) {
        for (final n in node) {
          final r = deep(n, depth + 1);
          if (r != null) return r;
        }
        return null;
      }
      if (node is Map) {
        final user = node['user'];
        if (user is Map) {
          final uname = user['username']?.toString();
          if (uname == null ||
              uname.toLowerCase() == username.toLowerCase()) {
            final id = fromUser(user);
            if (id != null) return id;
          }
        }
        for (final v in node.values) {
          final r = deep(v, depth + 1);
          if (r != null) return r;
        }
      }
      return null;
    }

    return deep(data, 0);
  }

  bool _looksLikeStoryMediaUrl(String url) {
    final lower = url.toLowerCase();
    if (lower.startsWith('blob:')) return false;
    if (!(lower.contains('cdninstagram.com') ||
        lower.contains('fbcdn.net') ||
        lower.contains('instagram.'))) {
      return false;
    }
    if (lower.contains('s150x150') ||
        lower.contains('s100x100') ||
        lower.contains('s240x240') ||
        lower.contains('s320x320') ||
        lower.contains('profile_pic') ||
        lower.contains('/rsrc.php') ||
        lower.contains('static.cdninstagram')) {
      return false;
    }
    return lower.contains('.mp4') ||
        lower.contains('video') ||
        lower.contains('.jpg') ||
        lower.contains('.jpeg') ||
        lower.contains('.webp') ||
        lower.contains('stp=dst-jpg') ||
        lower.contains('stp=dst-webp') ||
        lower.contains('/t51.') ||
        lower.contains('/t50.') ||
        lower.contains('/t35.') ||
        lower.contains('/o1/v/');
  }

  /// Install persistent fetch/XHR + resource hooks so we can read stories
  /// even when Instagram's tray API is empty / blocked.
  Future<void> _installStoryCaptureHooks(
    InAppWebViewController controller,
  ) async {
    try {
      await controller.evaluateJavascript(source: r'''
(function () {
  if (window.__qsStoryHook) return;
  window.__qsStoryHook = true;
  window.__qsStoryMedia = window.__qsStoryMedia || [];
  window.__qsStoryPayload = window.__qsStoryPayload || null;

  function pushUrl(u) {
    try {
      if (!u || typeof u !== 'string') return;
      if (u.indexOf('http') !== 0) return;
      if (u.indexOf('blob:') === 0) return;
      var l = u.toLowerCase();
      if (!(l.indexOf('cdninstagram') >= 0 || l.indexOf('fbcdn') >= 0)) return;
      if (l.indexOf('s150x150') >= 0 || l.indexOf('s100x100') >= 0) return;
      if (window.__qsStoryMedia.indexOf(u) === -1) {
        window.__qsStoryMedia.push(u);
        if (window.__qsStoryMedia.length > 60) window.__qsStoryMedia.shift();
      }
      if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('onStoryMediaUrl', u);
      }
    } catch (e) {}
  }

  function scanText(text, url) {
    try {
      if (!text || text.length < 40) return;
      var u = String(url || '').toLowerCase();
      var isStoryApi =
        u.indexOf('reels_media') >= 0 ||
        u.indexOf('/story') >= 0 ||
        u.indexOf('feed/user') >= 0 ||
        u.indexOf('graphql') >= 0 && (
          text.indexOf('reels_media') >= 0 ||
          text.indexOf('expiring_at') >= 0 ||
          text.indexOf('stories') >= 0
        ) ||
        (text.indexOf('expiring_at') >= 0 && text.indexOf('image_versions2') >= 0);
      var interesting =
        u.indexOf('reels_media') >= 0 ||
        u.indexOf('/story') >= 0 ||
        u.indexOf('graphql') >= 0 ||
        u.indexOf('api/v1') >= 0 ||
        isStoryApi;
      if (interesting) {
        try {
          console.log('[qsHook] scanText url=' + String(url || '').slice(0, 180) +
            ' len=' + text.length + ' storyApi=' + isStoryApi);
        } catch (e0) {}
        try {
          if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
            window.flutter_inappwebview.callHandler('onQsHookDiag',
              'scanText len=' + text.length + ' storyApi=' + isStoryApi +
              ' url=' + String(url || '').slice(0, 180));
          }
        } catch (e1) {}
      }
      if (isStoryApi &&
          (text.indexOf('image_versions2') >= 0 || text.indexOf('video_versions') >= 0 ||
           text.indexOf('reels_media') >= 0 || text.indexOf('expiring_at') >= 0)) {
        try { window.__qsStoryPayload = JSON.parse(text); } catch (e) {
          try { window.__qsStoryPayload = text; } catch (e2) {}
        }
        try {
          var keys = [];
          var uname = null;
          var hasStory = false;
          if (window.__qsStoryPayload && typeof window.__qsStoryPayload === 'object') {
            keys = Object.keys(window.__qsStoryPayload).slice(0, 12);
            function deepUser(n, d) {
              if (!n || d > 8) return null;
              if (n.user && n.user.username) return n.user.username;
              if (Array.isArray(n)) {
                for (var i = 0; i < n.length; i++) {
                  var r = deepUser(n[i], d + 1); if (r) return r;
                }
                return null;
              }
              if (typeof n === 'object') {
                for (var k in n) {
                  if (Object.prototype.hasOwnProperty.call(n, k)) {
                    var r2 = deepUser(n[k], d + 1); if (r2) return r2;
                  }
                }
              }
              return null;
            }
            function deepStory(n, d) {
              if (!n || d > 8) return false;
              if (Array.isArray(n)) {
                for (var i = 0; i < n.length; i++) if (deepStory(n[i], d + 1)) return true;
                return false;
              }
              if (typeof n !== 'object') return false;
              if ((n.image_versions2 || n.video_versions) && (n.expiring_at || n.taken_at)) return true;
              for (var k in n) {
                if (Object.prototype.hasOwnProperty.call(n, k) && deepStory(n[k], d + 1)) return true;
              }
              return false;
            }
            uname = deepUser(window.__qsStoryPayload, 0);
            hasStory = deepStory(window.__qsStoryPayload, 0);
          }
          console.log('[qsHook] captured keys=' + keys.join(',') +
            ' user=' + uname + ' hasStory=' + hasStory);
        } catch (e3) {}
        if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
          window.flutter_inappwebview.callHandler('onStoryApiPayload', text);
        }
      }
      // Only harvest CDN urls from story API bodies — not the whole feed.
      if (!isStoryApi) return;
      var re2 = /https:\/\/[^"'\s]+(?:cdninstagram|fbcdn\.net)[^"'\s]*/g;
      var m;
      while ((m = re2.exec(text)) !== null) {
        pushUrl(m[0]);
      }
    } catch (e) {}
  }

  var ofetch = window.fetch;
  window.fetch = function () {
    var args = arguments;
    var reqUrl = '';
    try {
      if (typeof args[0] === 'string') reqUrl = args[0];
      else if (args[0] && args[0].url) reqUrl = args[0].url;
    } catch (e) {}
    return ofetch.apply(this, args).then(function (res) {
      try {
        var u = (res && res.url) || reqUrl || '';
        pushUrl(u);
        res.clone().text().then(function (t) { scanText(t, u); }).catch(function () {});
      } catch (e) {}
      return res;
    });
  };

  try {
    var XO = XMLHttpRequest.prototype.open;
    var XS = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (method, url) {
      this.__qsUrl = url;
      return XO.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {
      var self = this;
      this.addEventListener('load', function () {
        try {
          pushUrl(String(self.__qsUrl || ''));
          scanText(self.responseText || '', self.__qsUrl || '');
        } catch (e) {}
      });
      return XS.apply(this, arguments);
    };
  } catch (e) {}

  function sweepDom() {
    try {
      // Only sweep large on-screen story media — not every feed thumbnail
      document.querySelectorAll('video').forEach(function (v) {
        var r = v.getBoundingClientRect();
        if (r.width >= 160 && r.height >= 220) {
          pushUrl(v.currentSrc || v.src || '');
        }
      });
      document.querySelectorAll('img').forEach(function (img) {
        var r = img.getBoundingClientRect();
        if (r.width >= 180 && r.height >= 240) {
          pushUrl(img.currentSrc || img.src || '');
        }
      });
    } catch (e) {}
  }
  sweepDom();
  setInterval(sweepDom, 2000);
})();
''');
    } catch (e) {
      if (kDebugMode) debugPrint('[Browser] story hook install failed: $e');
    }
  }

  Future<String?> _resolveStoryUsername() async {
    final fromUrl = _usernameFromStoryUrl(_pageUrl);
    if (fromUrl != null &&
        !_nonUserPaths.contains(fromUrl.toLowerCase())) {
      return fromUrl;
    }

    final controller = _controller;
    if (controller == null) return null;

    try {
      final result = await controller.callAsyncJavaScript(functionBody: r'''
        try {
          var blocked = {
            reel:1, reels:1, p:1, stories:1, explore:1, accounts:1, direct:1,
            notifications:1, highlights:1, inbox:1, liked:1, tagged:1, saved:1,
            shop:1, live:1, tv:1, guide:1, guides:1
          };
          var href = location.href || '';
          var m = href.match(/instagram\.com\/stories\/([A-Za-z0-9._]+)/i);
          if (m && m[1] && !blocked[m[1].toLowerCase()]) return m[1];
          var links = document.querySelectorAll('a[href*="/stories/"]');
          for (var i = 0; i < links.length; i++) {
            var hm = (links[i].getAttribute('href') || '').match(/\/stories\/([A-Za-z0-9._]+)/i);
            if (hm && hm[1] && !blocked[hm[1].toLowerCase()] &&
                hm[1].toLowerCase() !== 'highlights') return hm[1];
          }
          var headerLinks = document.querySelectorAll('header a[href^="/"]');
          for (var j = 0; j < headerLinks.length; j++) {
            var href2 = headerLinks[j].getAttribute('href') || '';
            var um = href2.match(/^\/([A-Za-z0-9._]+)\/?$/);
            if (um && um[1] && um[1].length > 1 && !blocked[um[1].toLowerCase()]) {
              return um[1];
            }
          }
        } catch (e) {}
        return null;
      ''');
      final v = result?.value?.toString();
      if (v != null &&
          v.isNotEmpty &&
          v != 'null' &&
          !_nonUserPaths.contains(v.toLowerCase())) {
        return v;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Browser] username resolve failed: $e');
    }
    return null;
  }

  /// Called after each page load. If the screen was opened with a story link
  /// directly (paste-and-go from the home screen) and the user is already
  /// logged in, skip the manual FAB tap and open the download sheet right
  /// away — otherwise the user is left looking at the bare Instagram story
  /// page with no obvious next step.
  Future<void> _maybeAutoTriggerDownload() async {
    if (!_isDirectStoryLink || _autoDownloadAttempted) return;
    if (!_loggedIn || !_onStoryPage || _fetchingTray) return;
    _autoDownloadAttempted = true;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    await _onDownloadFabPressed();
  }

  Future<void> _onDownloadFabPressed() async {
    await _refreshSessionFlag();
    if (!_loggedIn) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Log into Instagram on this page first. We never store your password.',
          ),
          duration: Duration(seconds: 4),
        ),
      );
      await _controller?.loadUrl(
        urlRequest: URLRequest(
          url: WebUri('https://www.instagram.com/accounts/login/'),
        ),
      );
      return;
    }

    setState(() => _fetchingTray = true);
    try {
      final c = _controller;
      if (c != null) {
        await _refreshStoryUiFlag(c);
        await _installStoryCaptureHooks(c);
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }

      final username = await _resolveStoryUsername() ?? 'story';
      print('[Browser] resolved username=$username pageUrl=$_pageUrl');

      if (_nonUserPaths.contains(username.toLowerCase()) ||
          username == 'story') {
        _lastTrayDebug = 'not a story user: $username';
        print('[Browser] $_lastTrayDebug');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Open someone’s story first, then tap download.',
              ),
              duration: Duration(seconds: 4),
            ),
          );
        }
        return;
      }

      // Treat as story view during this tap even if URL bar hid /stories/.
      if (!_onStoryPage && mounted) {
        setState(() => _onStoryPage = true);
      }

      if (_lastFetchedUsername != null &&
          _lastFetchedUsername!.toLowerCase() != username.toLowerCase()) {
        print(
          '[Browser] username changed '
          '$_lastFetchedUsername → $username — dropping stale URL cache only',
        );
        // Do NOT clear window.__qsStoryPayload / _capturedTrayPayload here.
        // IG's SPA may already have fetched fresh reels_media for the NEW user
        // via our hooks. Username-match guards reject wrong-user payloads.
        _capturedStoryUrls.clear();
      }
      _lastFetchedUsername = username;

      // Prefer passively-captured tray; brief retries in case the new story's
      // network payload is still in flight when the FAB is tapped.
      StoryTrayResult? tray;
      for (var attempt = 0; attempt < 3 && tray == null; attempt++) {
        await _syncCapturedPayloadFromWebView();
        tray = _trayFromCapturedPayload(username);
        if (tray != null) break;
        if (attempt < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }
      if (tray != null) {
        _lastTrayDebug = 'ok source=cache items=${tray.items.length}';
        print('[Browser] tray $_lastTrayDebug');
        _cacheUserIdFromPayload(username, _capturedTrayPayload);
      }

      // Only hit live APIs if nothing matching was captured while browsing.
      if (tray == null || tray.items.isEmpty) {
        tray = await _fetchStoryTray(username);
      }

      var currentItems = await _extractCurrentStorySlide();
      if (currentItems.isEmpty) {
        currentItems = await _extractFromNetworkLog();
      }
      print(
        '[Browser] trayItems=${tray?.items.length ?? 0} '
        'currentItems=${currentItems.length} debug=$_lastTrayDebug',
      );

      List<StoryTrayItem> merged;
      String? preferredId;
      if (tray != null && tray.items.isNotEmpty) {
        merged = tray.items;
        preferredId = _bestMatchId(tray.items, currentItems);
      } else if (currentItems.isNotEmpty) {
        merged = [currentItems.first];
        preferredId = merged.first.id;
        if (mounted) {
          final diag = _lastTrayDebug ?? 'unknown';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Tray failed — showing 1 slide only.\n$diag',
              ),
              duration: const Duration(seconds: 8),
            ),
          );
        }
      } else {
        final caps = _recentStoryCapturesAsItems();
        merged = caps.isEmpty ? const [] : [caps.first];
        preferredId = merged.isEmpty ? null : merged.first.id;
      }

      if (!mounted) return;
      if (merged.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Couldn’t grab this slide yet. Wait until the story finishes loading, then tap download again.',
            ),
            duration: Duration(seconds: 5),
          ),
        );
        return;
      }

      // Prefetch previews via WebView cookies (CDN blocks normal Image.network).
      final thumbBytes = await _prefetchStoryThumbnails(merged);

      if (!mounted) return;
      await _showDownloadOptionsSheet(
        StoryTrayResult(
          username: username,
          profilePicUrl: tray?.profilePicUrl,
          items: merged,
        ),
        preferredId: preferredId,
        thumbBytes: thumbBytes,
      );
    } finally {
      if (mounted) setState(() => _fetchingTray = false);
    }
  }

  List<StoryTrayItem> _recentStoryCapturesAsItems() {
    final items = <StoryTrayItem>[];
    final seen = <String>{};
    for (final url in _capturedStoryUrls.reversed) {
      if (!seen.add(url)) continue;
      // Prefer real story/post media paths; skip tiny UI assets already filtered.
      final isVideo = InstagramCdnUtils.isLikelyMp4Video(url) ||
          url.toLowerCase().contains('.mp4');
      items.add(
        StoryTrayItem(
          id: 'cap_${seen.length}',
          mediaUrl: url,
          mediaType: isVideo ? 'video' : 'image',
          thumbnailUrl: url,
        ),
      );
      if (items.length >= 3) break;
    }
    return items;
  }

  /// Match the on-screen slide to a tray item for pre-selection.
  String? _bestMatchId(
    List<StoryTrayItem> tray,
    List<StoryTrayItem> current,
  ) {
    if (tray.isEmpty) return null;
    if (current.isEmpty) return tray.first.id;
    String norm(String u) {
      try {
        return Uri.parse(u).path;
      } catch (_) {
        return u.split('?').first;
      }
    }

    for (final cur in current) {
      final np = norm(cur.mediaUrl);
      for (final item in tray) {
        if (norm(item.mediaUrl) == np ||
            norm(item.thumbnailUrl ?? '') == np ||
            item.mediaUrl == cur.mediaUrl) {
          return item.id;
        }
      }
    }
    return tray.first.id;
  }

  /// Smaller CDN URL for sheet previews (faster + less 403 noise).
  String _previewThumbUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final params = Map<String, String>.from(uri.queryParameters);
      if (params.containsKey('stp')) {
        params['stp'] = params['stp']!.replaceAllMapped(
          RegExp(r's\d{2,4}x\d{2,4}'),
          (_) => 's320x320',
        );
        return uri.replace(queryParameters: params).toString();
      }
    } catch (_) {}
    return url;
  }

  /// Prefetch sheet previews. Prefer native GET on signed CDN URLs (no cookies).
  Future<Map<String, Uint8List>> _prefetchStoryThumbnails(
    List<StoryTrayItem> items,
  ) async {
    final out = <String, Uint8List>{};
    for (final item in items) {
      final raw = item.thumbnailUrl;
      final url = (raw != null &&
              raw.isNotEmpty &&
              !raw.toLowerCase().contains('.mp4'))
          ? raw
          : (item.isVideo ? null : item.mediaUrl);
      if (url == null || url.isEmpty) continue;
      final preview = _previewThumbUrl(url);
      final bytes = await _downloadCdnBytes(preview);
      if (bytes != null && bytes.isNotEmpty) {
        out[item.id] = Uint8List.fromList(bytes);
      }
    }
    return out;
  }

  /// Signed Instagram CDN URLs usually work without cookies; cookies can 403.
  Future<List<int>?> _downloadCdnBytes(String url) async {
    final clean = url.replaceAll('&amp;', '&');
    try {
      final dio = Dio();
      final res = await dio.get<List<int>>(
        clean,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          validateStatus: (s) => s != null && s >= 200 && s < 400,
          headers: {
            ...InstagramCdnUtils.downloadHeaders,
            'Referer': (_pageUrl != null && _pageUrl!.startsWith('http'))
                ? _pageUrl!
                : 'https://www.instagram.com/',
          },
        ),
      );
      final data = res.data;
      if (data != null && data.length > 64) return data;
    } catch (e) {
      if (kDebugMode) debugPrint('[Browser] CDN GET failed: $e');
    }
    // Fallback: WebView fetch (may fail CORS on some CDNs).
    return _fetchMediaBytesViaWebView(clean);
  }

  Future<StoryTrayResult?> _fetchStoryTray(String username) async {
    final controller = _controller;
    if (controller == null) return null;

    try {
      // Parse tray fully in JS and return a slim item list.
      // Full reels_media JSON is often too large for the JS↔Dart bridge
      // (8+ stories), which made us fall back to a single current slide.
      final result = await controller.callAsyncJavaScript(
        functionBody: '''
          const username = ${jsonEncode(username)};
          const cachedUserId = ${jsonEncode(_userIdCache[username])};
          function csrf() {
            try {
              var m = document.cookie.match(/(?:^|;\\s*)csrftoken=([^;]+)/);
              return m ? decodeURIComponent(m[1]) : '';
            } catch (e) { return ''; }
          }
          function bestUrl(list) {
            if (!list || !list.length) return null;
            var best = null, bestArea = -1;
            for (var i = 0; i < list.length; i++) {
              var v = list[i];
              if (!v || !v.url) continue;
              var area = (v.width || 0) * (v.height || 0);
              if (area >= bestArea) { bestArea = area; best = v.url; }
            }
            return best;
          }
          function slimFromPayload(data) {
            // The username only lives on the reel wrapper (reels_media[i],
            // reels[key]), never on each story item — so a multi-reel
            // payload (e.g. a tray captured while scrolling the home feed)
            // must be filtered HERE, before flattening items, or another
            // user's slides get attributed to `username`.
            var out = [];
            var seen = {};
            var want = String(username || '').toLowerCase();
            // Verify whenever the reel actually names an owner — even a
            // SINGLE-reel response can be for the wrong account (the id it
            // was fetched with came from a fragile page-scrape guess that can
            // resolve to a completely different user's id). Only skip the
            // check when the reel truly carries no user info at all, since
            // then there's nothing to verify against.
            function reelOwnerOk(reel) {
              if (!want) return true;
              if (reel && reel.user && reel.user.username) {
                return String(reel.user.username).toLowerCase() === want;
              }
              return true;
            }
            function addList(list) {
              if (!list || !list.length) return;
              for (var i = 0; i < list.length; i++) {
                var it = list[i];
                if (!it) continue;
                if (!it.expiring_at && !it.taken_at) continue;
                var id = String(it.pk || it.id || '');
                if (!id || seen[id]) continue;
                var videoUrl = bestUrl(it.video_versions);
                var imageUrl = it.image_versions2
                  ? bestUrl(it.image_versions2.candidates) : null;
                if (!videoUrl && !imageUrl) continue;
                seen[id] = true;
                var isVideo = (it.media_type === 2) || (!!videoUrl && it.media_type !== 1);
                out.push({
                  id: id,
                  mediaUrl: isVideo ? (videoUrl || imageUrl) : (imageUrl || videoUrl),
                  thumbnailUrl: imageUrl || '',
                  mediaType: isVideo ? 'video' : 'image'
                });
              }
            }
            if (!data) return out;
            if (data.reels_media && data.reels_media.length) {
              for (var r = 0; r < data.reels_media.length; r++) {
                var reelM = data.reels_media[r];
                if (!reelOwnerOk(reelM)) continue;
                addList(reelM && reelM.items);
              }
            }
            if (data.reels) {
              var keys = Object.keys(data.reels);
              for (var k = 0; k < keys.length; k++) {
                var reelK = data.reels[keys[k]];
                if (!reelOwnerOk(reelK)) continue;
                addList(reelK && reelK.items);
              }
            }
            if (data.reel && data.reel.items && reelOwnerOk(data.reel)) {
              addList(data.reel.items);
            }
            if (out.length) return out;
            return slimFromAnyPayload(data, username);
          }
          function deepFindStoryItems(node, out, seen, depth, ctxUser) {
            if (!node || depth > 8) return;
            if (Array.isArray(node)) {
              for (var i = 0; i < node.length; i++) {
                deepFindStoryItems(node[i], out, seen, depth + 1, ctxUser);
              }
              return;
            }
            if (typeof node !== 'object') return;
            // Track the nearest enclosing `user` we've seen while descending —
            // individual story items rarely carry their own `user` field, only
            // the reel/tray wrapper around them does.
            var nextCtx = ctxUser;
            if (node.user && node.user.username) {
              nextCtx = String(node.user.username).toLowerCase();
            }
            var looksLikeItem = (node.image_versions2 || node.video_versions) &&
              (node.expiring_at || node.taken_at);
            if (looksLikeItem) {
              var id = String(node.pk || node.id || '');
              if (id && !seen[id]) {
                seen[id] = true;
                out.push({ item: node, ownerUsername: nextCtx });
              }
            }
            for (var key in node) {
              if (Object.prototype.hasOwnProperty.call(node, key)) {
                deepFindStoryItems(node[key], out, seen, depth + 1, nextCtx);
              }
            }
          }
          function slimFromAnyPayload(data, wantUsername) {
            var rawItems = [];
            var seen = {};
            deepFindStoryItems(data, rawItems, seen, 0, null);
            var want = wantUsername ? String(wantUsername).toLowerCase() : '';
            var out = [];
            for (var i = 0; i < rawItems.length; i++) {
              var entry = rawItems[i];
              var it = entry.item;
              // Reject only a CONFIRMED other-user context; an item with no
              // determinable owner (no enclosing `user` node anywhere above
              // it) is kept, since that's the common shape for a single-user
              // fetch that never wraps items in a `user`-tagged reel object.
              if (want && entry.ownerUsername && entry.ownerUsername !== want) continue;
              var id = String(it.pk || it.id || '');
              var videoUrl = bestUrl(it.video_versions);
              var imageUrl = it.image_versions2
                ? bestUrl(it.image_versions2.candidates) : null;
              if (!videoUrl && !imageUrl) continue;
              var isVideo = (it.media_type === 2) || (!!videoUrl && it.media_type !== 1);
              out.push({
                id: id,
                mediaUrl: isVideo ? (videoUrl || imageUrl) : (imageUrl || videoUrl),
                thumbnailUrl: imageUrl || '',
                mediaType: isVideo ? 'video' : 'image'
              });
            }
            return out;
          }
          function deepFindUsername(node, depth) {
            if (!node || depth > 8 || typeof node !== 'object') return null;
            if (node.user && node.user.username) return String(node.user.username);
            if (Array.isArray(node)) {
              for (var i = 0; i < node.length; i++) {
                var r = deepFindUsername(node[i], depth + 1);
                if (r) return r;
              }
              return null;
            }
            for (var key in node) {
              if (Object.prototype.hasOwnProperty.call(node, key)) {
                var r2 = deepFindUsername(node[key], depth + 1);
                if (r2) return r2;
              }
            }
            return null;
          }
          function deepHasStoryItem(node, depth) {
            if (!node || depth > 8) return false;
            if (Array.isArray(node)) {
              for (var i = 0; i < node.length; i++) {
                if (deepHasStoryItem(node[i], depth + 1)) return true;
              }
              return false;
            }
            if (typeof node !== 'object') return false;
            if ((node.image_versions2 || node.video_versions) &&
                (node.expiring_at || node.taken_at)) return true;
            for (var key in node) {
              if (Object.prototype.hasOwnProperty.call(node, key)) {
                if (deepHasStoryItem(node[key], depth + 1)) return true;
              }
            }
            return false;
          }
          function countStorySegments() {
            try {
              var best = 0;
              var nodes = document.querySelectorAll('div');
              for (var i = 0; i < nodes.length; i++) {
                var d = nodes[i];
                var r = d.getBoundingClientRect();
                if (r.top > 140 || r.height <= 0 || r.height > 5 || r.width < 16) continue;
                var p = d.parentElement;
                if (!p) continue;
                var kids = p.children;
                var thin = 0;
                for (var j = 0; j < kids.length; j++) {
                  var kr = kids[j].getBoundingClientRect();
                  if (kr.height > 0 && kr.height <= 5 && kr.width > 10) thin++;
                }
                if (thin > best && thin < 40) best = thin;
              }
              return best;
            } catch (e) { return 0; }
          }
          function extractUserId(data, uname) {
            function fromUser(u) {
              if (!u) return null;
              var id = u.id != null ? String(u.id) : (u.pk != null ? String(u.pk) : null);
              if (id && /^\\d{5,}\$/.test(id)) return id;
              return null;
            }
            function deep(node, depth) {
              if (!node || depth > 8) return null;
              if (Array.isArray(node)) {
                for (var i = 0; i < node.length; i++) {
                  var r = deep(node[i], depth + 1);
                  if (r) return r;
                }
                return null;
              }
              if (typeof node !== 'object') return null;
              if (node.user) {
                var un = node.user.username ? String(node.user.username).toLowerCase() : '';
                if (!uname || !un || un === String(uname).toLowerCase()) {
                  var idu = fromUser(node.user);
                  if (idu) return idu;
                }
              }
              for (var key in node) {
                if (Object.prototype.hasOwnProperty.call(node, key)) {
                  var r2 = deep(node[key], depth + 1);
                  if (r2) return r2;
                }
              }
              return null;
            }
            if (!data) return null;
            if (data.reels_media && data.reels_media[0]) {
              var a = fromUser(data.reels_media[0].user);
              if (a) return a;
            }
            if (data.reel && data.reel.user) {
              var b = fromUser(data.reel.user);
              if (b) return b;
            }
            if (data.reels) {
              var keys = Object.keys(data.reels);
              for (var i = 0; i < keys.length; i++) {
                if (/^\\d{5,}\$/.test(keys[i])) return keys[i];
                var c = fromUser(data.reels[keys[i]] && data.reels[keys[i]].user);
                if (c) return c;
              }
            }
            var fromTop = fromUser(data.user);
            if (fromTop) return fromTop;
            return deep(data, 0);
          }
          function findUserIdFromPage(uname) {
            try {
              var payload = window.__qsStoryPayload;
              if (typeof payload === 'string') {
                try { payload = JSON.parse(payload); } catch (e) { payload = null; }
              }
              var fromPayload = extractUserId(payload, uname);
              if (fromPayload) return fromPayload;

              var link = document.querySelector(
                'a[href*="/' + uname + '/"][data-userid], a[href*="/' + uname + '/"][data-user-id]'
              );
              if (link) {
                var du = link.getAttribute('data-userid') || link.getAttribute('data-user-id');
                if (du && /^\\d{5,}\$/.test(du)) return du;
              }

              var lower = String(uname || '').toLowerCase();
              var scripts = document.querySelectorAll('script[type="application/json"], script');
              for (var i = 0; i < scripts.length; i++) {
                var txt = scripts[i].textContent || '';
                if (txt.length < 40 || txt.toLowerCase().indexOf(lower) === -1) continue;
                if (txt.length > 800000) txt = txt.slice(0, 800000);
                var re1 = /"id"\\s*:\\s*"?(\\d{5,})"?[\\s\\S]{0,160}"username"\\s*:\\s*"([^"]+)"/gi;
                var m;
                while ((m = re1.exec(txt)) !== null) {
                  if (String(m[2]).toLowerCase() === lower) return m[1];
                }
                var re2 = /"username"\\s*:\\s*"([^"]+)"[\\s\\S]{0,160}"id"\\s*:\\s*"?(\\d{5,})"?/gi;
                while ((m = re2.exec(txt)) !== null) {
                  if (String(m[1]).toLowerCase() === lower) return m[2];
                }
                var re3 = /"username"\\s*:\\s*"([^"]+)"[\\s\\S]{0,120}"pk"\\s*:\\s*"?(\\d{5,})"?/gi;
                while ((m = re3.exec(txt)) !== null) {
                  if (String(m[1]).toLowerCase() === lower) return m[2];
                }
              }
            } catch (e) {}
            return null;
          }
          const headers = {
            'X-IG-App-ID': '$_igAppId',
            'Accept': '*/*',
            'X-Requested-With': 'XMLHttpRequest',
            'X-CSRFToken': csrf(),
            'X-ASBD-ID': '359341',
            'X-IG-WWW-Claim': '0',
            'Referer': location.href || 'https://www.instagram.com/',
            'Origin': 'https://www.instagram.com'
          };
          function noteClaim(res) {
            try {
              var c = res.headers.get('x-ig-set-www-claim');
              if (c) {
                headers['X-IG-WWW-Claim'] = c;
                try { sessionStorage.setItem('qs_ig_www_claim', c); } catch (e2) {}
              }
            } catch (e) {}
          }
          // A real 429 means IG has already flagged this session — hammering
          // it again on the very next story (up to 7 requests per attempt:
          // 3 POST bodies, 3 GET fallbacks, 1 profile lookup) only extends
          // the block. Remember it and back off for a cooldown window instead
          // of spending the whole request budget again just to get 429'd.
          function noteRateLimited() {
            try {
              sessionStorage.setItem('qs_ig_429_until', String(Date.now() + 120000));
            } catch (e) {}
          }
          function rateLimitCooldownRemaining() {
            try {
              var until = parseInt(sessionStorage.getItem('qs_ig_429_until') || '0', 10);
              return until > Date.now() ? until - Date.now() : 0;
            } catch (e) { return 0; }
          }
          try {
            var cooldownMs = rateLimitCooldownRemaining();
            if (cooldownMs > 0) {
              return {
                rateLimited: true,
                cooldown: true,
                status: 429,
                attempts: [{ step: 'cooldown', remainingMs: cooldownMs }]
              };
            }
            try {
              var storedClaim = sessionStorage.getItem('qs_ig_www_claim');
              if (storedClaim) headers['X-IG-WWW-Claim'] = storedClaim;
            } catch (e) {}
            let items = [];
            let source = 'api';
            const attempts = [];
            let id;
            let profilePic = '';
            let resolvedUsername = username;

            // 0) Prefer passively captured story payload — only if it matches
            // this username (stale captures from a prior swipe must be ignored).
            if (window.__qsStoryPayload) {
              var cachedPayload = window.__qsStoryPayload;
              if (typeof cachedPayload === 'string') {
                try { cachedPayload = JSON.parse(cachedPayload); } catch (e) { cachedPayload = null; }
              }
              var cacheUserOk = false;
              try {
                var want = String(username || '').toLowerCase();
                var foundUser = deepFindUsername(cachedPayload, 0);
                if (foundUser && String(foundUser).toLowerCase() === want) {
                  cacheUserOk = true;
                } else if (deepHasStoryItem(cachedPayload, 0)) {
                  // Payload has story items; accept if slim filter yields any for this user.
                  var probe = slimFromAnyPayload(cachedPayload, username);
                  cacheUserOk = probe.length > 0;
                }
              } catch (e) { cacheUserOk = false; }
              attempts.push({ step: 'cache', match: cacheUserOk });
              var dbgUser = null;
              try {
                dbgUser = deepFindUsername(cachedPayload, 0);
              } catch (e3) {}
              attempts.push({
                step: 'cache_debug',
                hasPayload: !!cachedPayload,
                payloadKeys: cachedPayload ? Object.keys(cachedPayload).slice(0, 16) : [],
                payloadUser: dbgUser || null,
                hasStoryNodes: deepHasStoryItem(cachedPayload, 0)
              });
              if (cacheUserOk) {
                items = slimFromPayload(cachedPayload);
                if (!items.length) items = slimFromAnyPayload(cachedPayload, username);
                attempts.push({ step: 'cache_items', items: items.length });
                if (items.length) {
                  id = extractUserId(cachedPayload, username) ||
                    (cachedUserId ? String(cachedUserId) : null);
                  return {
                    ok: true,
                    username: resolvedUsername,
                    profilePic: profilePic,
                    userId: id,
                    items: items,
                    source: 'cache',
                    segments: countStorySegments(),
                    attempts: attempts
                  };
                }
              } else {
                // Keep mismatched payload for diagnostics; don't wipe while debugging capture.
              }
            } else {
              attempts.push({ step: 'cache', match: false });
              attempts.push({
                step: 'cache_debug',
                hasPayload: false,
                payloadKeys: [],
                payloadUser: null
              });
            }

            // Resolve numeric user id: cache → page scrape.
            // Skip web_profile_info while this session is 429-flagged (extends the ban).
            if (cachedUserId) {
              id = String(cachedUserId);
              attempts.push({ step: 'profile', status: 'cached', id: id });
            } else {
              id = findUserIdFromPage(username);
              if (id) {
                attempts.push({ step: 'profile', status: 'page', id: id });
              } else {
                attempts.push({
                  step: 'profile',
                  status: 'skipped_web_profile_info',
                  reason: 'cooldown_avoid_429'
                });
                return {
                  error: 'no_user_id',
                  attempts: attempts,
                  hint: 'Wait for story network capture, or cool down before profile API'
                };
              }
            }

            // 1) POST reels_media — try several body shapes IG accepts
            const bodies = [
              'reel_ids=' + encodeURIComponent(JSON.stringify([id])),
              'reel_ids=["' + id + '"]',
              'reel_ids=' + id
            ];
            for (var bi = 0; bi < bodies.length && !items.length; bi++) {
              try {
                const postRes = await fetch(
                  'https://www.instagram.com/api/v1/feed/reels_media/',
                  {
                    method: 'POST',
                    credentials: 'include',
                    headers: Object.assign({}, headers, {
                      'Content-Type': 'application/x-www-form-urlencoded'
                    }),
                    body: bodies[bi]
                  }
                );
                noteClaim(postRes);
                attempts.push({
                  step: 'post_reels_' + bi,
                  status: postRes.status,
                  claim: headers['X-IG-WWW-Claim']
                });
                if (postRes.status === 429) {
                  noteRateLimited();
                  return { rateLimited: true, status: 429, attempts: attempts };
                }
                if (postRes.ok) {
                  const postText = await postRes.text();
                  try {
                    items = slimFromPayload(JSON.parse(postText));
                    attempts[attempts.length - 1].items = items.length;
                  } catch (e) {
                    attempts[attempts.length - 1].error = 'not_json';
                    attempts[attempts.length - 1].snippet = postText.slice(0, 120);
                  }
                }
              } catch (e) {
                attempts.push({ step: 'post_reels_' + bi, error: String(e) });
              }
            }

            // 2) GET fallbacks
            if (!items.length) {
              const reelUrls = [
                'https://www.instagram.com/api/v1/feed/reels_media/?reel_ids=' + encodeURIComponent(id),
                'https://i.instagram.com/api/v1/feed/reels_media/?reel_ids=' + encodeURIComponent(id),
                'https://www.instagram.com/api/v1/feed/user/' + encodeURIComponent(id) + '/story/'
              ];
              for (const url of reelUrls) {
                try {
                  const reelsRes = await fetch(url, { credentials: 'include', headers: headers });
                  noteClaim(reelsRes);
                  attempts.push({
                    step: 'get',
                    url: url,
                    status: reelsRes.status,
                    claim: headers['X-IG-WWW-Claim']
                  });
                  if (reelsRes.status === 429) {
                    noteRateLimited();
                    return { rateLimited: true, status: 429, attempts: attempts };
                  }
                  if (reelsRes.status === 401 || reelsRes.status === 403) {
                    return {
                      requiresLogin: true,
                      status: reelsRes.status,
                      attempts: attempts
                    };
                  }
                  if (!reelsRes.ok) continue;
                  const getText = await reelsRes.text();
                  try {
                    items = slimFromPayload(JSON.parse(getText));
                    attempts[attempts.length - 1].items = items.length;
                  } catch (e) {
                    attempts[attempts.length - 1].error = 'not_json';
                    attempts[attempts.length - 1].snippet = getText.slice(0, 120);
                    continue;
                  }
                  if (items.length) break;
                } catch (e) {
                  attempts.push({ step: 'get', url: url, error: String(e) });
                }
              }
            }

            // 2.5) Every reel_ids lookup above came back empty (200/400, never
            // a real payload) even though the story is visibly playing on
            // screen — the usual cause is a WRONG numeric id: `id` above came
            // from best-effort regex scraping of arbitrary <script> tags on
            // the page (there is no cache hit and no real profile lookup was
            // ever attempted), and a nearby unrelated id/username pair (e.g.
            // a suggested-accounts widget) can be picked up by mistake. Only
            // web_profile_info actually ties an id to a username server-side,
            // so use it once, here, as a last resort before giving up — never
            // upfront, to avoid tripping IG's rate limit on every tap.
            if (!items.length && !cachedUserId) {
              try {
                const profRes = await fetch(
                  'https://www.instagram.com/api/v1/users/web_profile_info/?username=' +
                    encodeURIComponent(username),
                  { credentials: 'include', headers: headers }
                );
                noteClaim(profRes);
                attempts.push({ step: 'web_profile_info', status: profRes.status });
                if (profRes.status === 429) {
                  noteRateLimited();
                  return { rateLimited: true, status: 429, attempts: attempts };
                }
                if (profRes.ok) {
                  const profJson = await profRes.json();
                  const confirmedId = profJson && profJson.data && profJson.data.user &&
                    profJson.data.user.id;
                  if (confirmedId && String(confirmedId) !== String(id)) {
                    id = String(confirmedId);
                    attempts.push({ step: 'profile_corrected', id: id });
                    const retryRes = await fetch(
                      'https://www.instagram.com/api/v1/feed/reels_media/?reel_ids=' +
                        encodeURIComponent(id),
                      { credentials: 'include', headers: headers }
                    );
                    noteClaim(retryRes);
                    attempts.push({ step: 'get_retry', status: retryRes.status });
                    if (retryRes.status === 429) {
                      noteRateLimited();
                      return { rateLimited: true, status: 429, attempts: attempts };
                    }
                    if (retryRes.ok) {
                      const retryText = await retryRes.text();
                      try {
                        items = slimFromPayload(JSON.parse(retryText));
                        attempts[attempts.length - 1].items = items.length;
                      } catch (e) {
                        attempts[attempts.length - 1].error = 'not_json';
                      }
                    }
                  }
                }
              } catch (e) {
                attempts.push({ step: 'web_profile_info', error: String(e) });
              }
            }

            // 3) Cached payload from while browsing this story
            if (!items.length && window.__qsStoryPayload) {
              items = slimFromPayload(window.__qsStoryPayload);
              source = 'cache';
              attempts.push({ step: 'cache', items: items.length });
            }

            if (!items.length) {
              return {
                error: 'no_reels',
                attempts: attempts,
                userId: id,
                username: resolvedUsername,
                profilePic: profilePic
              };
            }
            return {
              ok: true,
              username: resolvedUsername,
              profilePic: profilePic,
              userId: id,
              items: items,
              source: source,
              segments: countStorySegments(),
              attempts: attempts
            };
          } catch (e) {
            return { error: String(e) };
          }
        ''',
      );

      final decoded = result?.value;
      if (decoded is! Map) {
        _lastTrayDebug =
            'raw error=${result?.error} valueType=${decoded.runtimeType}';
        print('[Browser] tray raw error=${result?.error} value=$decoded');
        return null;
      }

      if (decoded['requiresLogin'] == true) {
        _lastTrayDebug = 'requiresLogin status=${decoded['status']} '
            'attempts=${decoded['attempts']}';
        print('[Browser] tray requiresLogin $_lastTrayDebug');
        if (mounted) {
          setState(() => _loggedIn = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Session expired. Please log in again.'),
            ),
          );
        }
        return null;
      }

      if (decoded['rateLimited'] == true) {
        final onCooldown = decoded['cooldown'] == true;
        _lastTrayDebug =
            'rateLimited cooldown=$onCooldown status=${decoded['status']} '
            'attempts=${decoded['attempts']}';
        print('[Browser] tray $_lastTrayDebug');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                onCooldown
                    ? 'Instagram rate-limited this session recently. Waiting it out — try again in a minute or two.'
                    : 'Instagram is rate-limiting requests. Wait a minute before trying again.',
              ),
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return null;
      }

      if (decoded['error']?.toString() == 'no_user_id') {
        _lastTrayDebug =
            'no_user_id attempts=${decoded['attempts']} hint=${decoded['hint']}';
        print('[Browser] tray $_lastTrayDebug');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Story data not ready yet. Swipe to the next slide, wait a second, then try again.',
              ),
              duration: Duration(seconds: 5),
            ),
          );
        }
        return null;
      }

      // Cache user id whenever JS resolved one (even on partial failure).
      final cachedId = decoded['userId']?.toString();
      if (cachedId != null && cachedId.isNotEmpty) {
        _userIdCache[username] = cachedId;
      }

      if (decoded['ok'] != true) {
        _lastTrayDebug =
            'error=${decoded['error']} attempts=${decoded['attempts']}';
        print('[Browser] tray not ok: $_lastTrayDebug');
        return null;
      }

      _lastTrayDebug =
          'ok source=${decoded['source']} segments=${decoded['segments']} '
          'attempts=${decoded['attempts']}';
      print('[Browser] tray $_lastTrayDebug');

      final rawItems = decoded['items'];
      if (rawItems is! List || rawItems.isEmpty) {
        _lastTrayDebug = '$_lastTrayDebug itemsEmpty';
        print('[Browser] tray items empty after ok');
        return null;
      }

      final items = <StoryTrayItem>[];
      final seen = <String>{};
      for (final row in rawItems) {
        if (row is! Map) continue;
        final id = row['id']?.toString() ?? '';
        final mediaUrl = row['mediaUrl']?.toString() ?? '';
        if (id.isEmpty || mediaUrl.isEmpty || !seen.add(id)) continue;
        final mediaType = row['mediaType']?.toString() == 'video'
            ? 'video'
            : 'image';
        final thumb = row['thumbnailUrl']?.toString();
        items.add(
          StoryTrayItem(
            id: id,
            mediaUrl: mediaUrl,
            mediaType: mediaType,
            thumbnailUrl: (thumb != null && thumb.isNotEmpty) ? thumb : null,
          ),
        );
      }
      if (items.isEmpty) return null;

      if (kDebugMode) {
        debugPrint(
          '[Browser] tray ${items.length} items source=${decoded['source']}',
        );
      }

      return StoryTrayResult(
        username: decoded['username']?.toString() ?? username,
        profilePicUrl: decoded['profilePic']?.toString(),
        items: items,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[Browser] tray fetch error: $e');
      return null;
    }
  }

  /// Only the currently visible story frame (not feed leftovers).
  Future<List<StoryTrayItem>> _extractCurrentStorySlide() async {
    final controller = _controller;
    if (controller == null) return const [];

    try {
      final result = await controller.callAsyncJavaScript(functionBody: r'''
        const out = [];
        const seen = {};
        function add(url, type, score) {
          if (!url || typeof url !== 'string') return;
          if (url.indexOf('blob:') === 0) return;
          if (url.indexOf('http') !== 0) return;
          var l = url.toLowerCase();
          if (!(l.indexOf('cdninstagram') >= 0 || l.indexOf('fbcdn') >= 0)) return;
          if (l.indexOf('s150x150') >= 0 || l.indexOf('s100x100') >= 0 ||
              l.indexOf('s240x240') >= 0 || l.indexOf('s320x320') >= 0 ||
              l.indexOf('profile_pic') >= 0 || l.indexOf('/rsrc.php') >= 0) return;
          if (seen[url]) return;
          seen[url] = true;
          out.push({ url: url, type: type || 'image', score: score || 0 });
        }

        document.querySelectorAll('video').forEach(function(v) {
          var r = v.getBoundingClientRect();
          var area = Math.max(0, r.width) * Math.max(0, r.height);
          if (area < 25000 && r.width < 120) return;
          var media = v.currentSrc || v.src || '';
          var poster = v.poster || '';
          var s = v.querySelector('source');
          if (!media && s) media = s.src || '';
          if (!media) return;
          if (seen[media]) return;
          seen[media] = true;
          out.push({
            url: media,
            type: 'video',
            poster: poster,
            score: area + 2000000
          });
        });

        // Letterboxed landscape stories often have height < 240 — use area.
        document.querySelectorAll('img').forEach(function(img) {
          var r = img.getBoundingClientRect();
          var dw = r.width || 0;
          var dh = r.height || 0;
          var area = dw * dh;
          if (area < 35000 && Math.max(dw, dh) < 200) return;
          if (dw < 90 || dh < 90) return;
          var score = area;
          if (area > 80000) score += 500000;
          if (dw >= 280) score += 200000;
          add(img.currentSrc || img.src || '', 'image', score);
          var ss = img.getAttribute('srcset') || '';
          if (ss) {
            var parts = ss.split(',');
            var last = parts[parts.length - 1];
            if (last) add(last.trim().split(/\s+/)[0], 'image', score + 5);
          }
        });

        document.querySelectorAll('[style*="background"]').forEach(function(el) {
          var r = el.getBoundingClientRect();
          var area = r.width * r.height;
          if (area < 35000) return;
          var st = el.getAttribute('style') || '';
          var m = st.match(/url\(["']?(https[^"')]+)["']?\)/i);
          if (m) add(m[1], 'image', area);
        });

        // Hooked media from this story session
        if (window.__qsStoryMedia && window.__qsStoryMedia.length) {
          for (var i = window.__qsStoryMedia.length - 1; i >= 0 && i >= window.__qsStoryMedia.length - 8; i--) {
            add(window.__qsStoryMedia[i], 'image', 100000);
          }
        }

        out.sort(function(a, b) { return (b.score || 0) - (a.score || 0); });
        return out.slice(0, 3);
      ''');

      final value = result?.value;
      if (value is! List || value.isEmpty) return const [];

      final items = <StoryTrayItem>[];
      for (var i = 0; i < value.length; i++) {
        final row = value[i];
        if (row is! Map) continue;
        final url = row['url']?.toString();
        final type = row['type']?.toString() ?? 'image';
        if (url == null || url.isEmpty) continue;
        _rememberStoryUrl(url, force: true);
        final isVideo = type == 'video' ||
            InstagramCdnUtils.isLikelyMp4Video(url) ||
            url.toLowerCase().contains('.mp4');
        final poster = row['poster']?.toString();
        final thumb = (poster != null &&
                poster.isNotEmpty &&
                !poster.toLowerCase().contains('.mp4'))
            ? poster
            : (isVideo ? null : url);
        if (thumb != null) _rememberStoryUrl(thumb, force: true);
        items.add(
          StoryTrayItem(
            id: 'current_$i',
            mediaUrl: url,
            mediaType: isVideo ? 'video' : 'image',
            thumbnailUrl: thumb,
          ),
        );
      }
      return items;
    } catch (e) {
      if (kDebugMode) debugPrint('[Browser] current slide extract failed: $e');
      return const [];
    }
  }

  /// Pull the largest recent CDN images the browser actually fetched.
  Future<List<StoryTrayItem>> _extractFromNetworkLog() async {
    final controller = _controller;
    if (controller == null) return const [];

    try {
      final result = await controller.callAsyncJavaScript(functionBody: r'''
        const out = [];
        const seen = {};
        function add(url, score) {
          if (!url || url.indexOf('http') !== 0) return;
          var l = url.toLowerCase();
          if (!(l.indexOf('cdninstagram') >= 0 || l.indexOf('fbcdn') >= 0)) return;
          if (l.indexOf('s150x150') >= 0 || l.indexOf('s100x100') >= 0 ||
              l.indexOf('s240x240') >= 0 || l.indexOf('s320x320') >= 0 ||
              l.indexOf('profile_pic') >= 0 || l.indexOf('/rsrc.php') >= 0) return;
          if (seen[url]) return;
          seen[url] = true;
          var type = (l.indexOf('.mp4') >= 0 || l.indexOf('/v/t50.') >= 0 || l.indexOf('video_dash') >= 0) ? 'video' : 'image';
          // Prefer story/post photo buckets
          if (l.indexOf('t51.2885-15') >= 0 || l.indexOf('t51.2885-19') >= 0) score += 50000;
          if (l.indexOf('s1080x1080') >= 0 || l.indexOf('s640x640') >= 0) score += 20000;
          out.push({ url: url, type: type, score: score });
        }
        try {
          if (window.performance && performance.getEntriesByType) {
            performance.getEntriesByType('resource').forEach(function(e) {
              var n = e.name || '';
              var sz = e.transferSize || e.encodedBodySize || 0;
              add(n, sz);
            });
          }
        } catch (e) {}
        if (window.__qsStoryMedia) {
          window.__qsStoryMedia.forEach(function(u) { add(u, 30000); });
        }
        out.sort(function(a, b) { return (b.score || 0) - (a.score || 0); });
        return out.slice(0, 3);
      ''');

      final value = result?.value;
      if (value is! List || value.isEmpty) return const [];

      final items = <StoryTrayItem>[];
      for (var i = 0; i < value.length; i++) {
        final row = value[i];
        if (row is! Map) continue;
        final url = row['url']?.toString();
        if (url == null || url.isEmpty) continue;
        _rememberStoryUrl(url, force: true);
        final type = row['type']?.toString() ?? 'image';
        items.add(
          StoryTrayItem(
            id: 'net_$i',
            mediaUrl: url,
            mediaType: type == 'video' ? 'video' : 'image',
            thumbnailUrl: url,
          ),
        );
      }
      return items;
    } catch (e) {
      if (kDebugMode) debugPrint('[Browser] network log extract failed: $e');
      return const [];
    }
  }

  /// False only on a CONFIRMED mismatch. Verify whenever the reel actually
  /// names an owner — even a single-reel payload can be for the wrong
  /// account (its id can come from a fragile page-scrape guess that
  /// resolved to a different user entirely), so this must not be skipped
  /// just because there's only one reel to look at. A reel with no user
  /// info at all is unverifiable and passes through unchanged.
  bool _reelBelongsToUser(Map reel, String want) {
    final user = reel['user'];
    if (user is Map) {
      final uname = user['username']?.toString();
      if (uname != null) return uname.toLowerCase() == want;
    }
    return true;
  }

  List<StoryTrayItem> _parseTrayItems(dynamic data, {String? forUsername}) {
    if (data == null) return const [];
    final items = <StoryTrayItem>[];
    final seen = <String>{};
    final want = forUsername?.toLowerCase();

    void addItem(Map map) {
      final hasMedia = map['image_versions2'] != null ||
          map['video_versions'] != null;
      if (!hasMedia) return;
      if (map['expiring_at'] == null && map['taken_at'] == null) return;

      if (want != null) {
        final user = map['user'];
        if (user is Map) {
          final uname = user['username']?.toString();
          if (uname != null && uname.toLowerCase() != want) return;
        }
      }

      final pk = '${map['pk'] ?? map['id'] ?? ''}';
      if (pk.isEmpty || seen.contains(pk)) return;
      seen.add(pk);

      final videoUrl = _bestVideoUrl(map['video_versions']);
      final imageUrl = _bestImageUrl(map['image_versions2']);
      final mediaTypeNum = (map['media_type'] as num?)?.toInt();
      if (videoUrl != null && (mediaTypeNum == null || mediaTypeNum == 2)) {
        items.add(
          StoryTrayItem(
            id: pk,
            mediaUrl: videoUrl,
            mediaType: 'video',
            thumbnailUrl: imageUrl,
            caption: map['caption']?.toString(),
          ),
        );
      } else if (imageUrl != null) {
        items.add(
          StoryTrayItem(
            id: pk,
            mediaUrl: imageUrl,
            mediaType: 'image',
            thumbnailUrl: imageUrl,
            caption: map['caption']?.toString(),
          ),
        );
      } else if (videoUrl != null) {
        items.add(
          StoryTrayItem(
            id: pk,
            mediaUrl: videoUrl,
            mediaType: 'video',
            thumbnailUrl: imageUrl,
            caption: map['caption']?.toString(),
          ),
        );
      }
    }

    void deepFind(dynamic node, int depth) {
      if (node == null || depth > 8) return;
      if (node is List) {
        for (final n in node) {
          deepFind(n, depth + 1);
        }
        return;
      }
      if (node is Map) {
        final map = Map<String, dynamic>.from(
          node.map((k, v) => MapEntry(k.toString(), v)),
        );
        final hasMedia = map['image_versions2'] != null ||
            map['video_versions'] != null;
        final hasExpiry =
            map['expiring_at'] != null || map['taken_at'] != null;
        if (hasMedia && hasExpiry) {
          addItem(map);
        }
        for (final v in map.values) {
          deepFind(v, depth + 1);
        }
      }
    }

    if (data is Map) {
      final map = Map<String, dynamic>.from(
        data.map((k, v) => MapEntry(k.toString(), v)),
      );

      // Prefer canonical REST trays when present.
      // `reels_media` / `reels` can hold a WHOLE tray (one entry per followed
      // user) when the payload was passively captured while scrolling the
      // home feed. The username only lives on the reel wrapper, not on each
      // story item — so it must be checked here, before descending into
      // `items`, or another user's slides bleed into this user's sheet.
      final reelsMedia = map['reels_media'];
      if (reelsMedia is List) {
        for (final reel in reelsMedia) {
          if (reel is Map) {
            if (want != null && !_reelBelongsToUser(reel, want)) continue;
            final list = reel['items'];
            if (list is List) {
              for (final n in list) {
                if (n is Map) {
                  addItem(
                    Map<String, dynamic>.from(
                      n.map((k, v) => MapEntry(k.toString(), v)),
                    ),
                  );
                }
              }
            }
          }
        }
      }

      final reels = map['reels'];
      if (reels is Map) {
        for (final reel in reels.values) {
          if (reel is Map) {
            if (want != null && !_reelBelongsToUser(reel, want)) continue;
            final list = reel['items'];
            if (list is List) {
              for (final n in list) {
                if (n is Map) {
                  addItem(
                    Map<String, dynamic>.from(
                      n.map((k, v) => MapEntry(k.toString(), v)),
                    ),
                  );
                }
              }
            }
          }
        }
      }

      final reel = map['reel'];
      if (reel is Map && (want == null || _reelBelongsToUser(reel, want))) {
        final list = reel['items'];
        if (list is List) {
          for (final n in list) {
            if (n is Map) {
              addItem(
                Map<String, dynamic>.from(
                  n.map((k, v) => MapEntry(k.toString(), v)),
                ),
              );
            }
          }
        }
      }

      // GraphQL / unknown nesting — deep scan for story-like media nodes.
      if (items.isEmpty) {
        deepFind(map, 0);
      }
    }

    // Deduplicate by CDN path (same slide can appear twice).
    final byPath = <String, StoryTrayItem>{};
    for (final item in items) {
      final key = () {
        try {
          return Uri.parse(item.mediaUrl).path;
        } catch (_) {
          return item.mediaUrl.split('?').first;
        }
      }();
      byPath.putIfAbsent(key, () => item);
    }
    return byPath.values.toList();
  }

  String? _bestVideoUrl(dynamic versions) {
    if (versions is! List || versions.isEmpty) return null;
    String? best;
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
        best = url;
      }
    }
    return best;
  }

  String? _bestImageUrl(dynamic imageVersions2) {
    if (imageVersions2 is! Map) return null;
    final candidates = imageVersions2['candidates'];
    if (candidates is! List || candidates.isEmpty) return null;
    String? best;
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
        best = url;
      }
    }
    return best;
  }

  Future<void> _showDownloadOptionsSheet(
    StoryTrayResult tray, {
    String? preferredId,
    Map<String, Uint8List>? thumbBytes,
  }) async {
    final selected = <String>{
      if (preferredId != null &&
          tray.items.any((e) => e.id == preferredId))
        preferredId
      else if (tray.items.isNotEmpty)
        tray.items.first.id,
    };

    final thumbs = thumbBytes ?? const <String, Uint8List>{};

    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.darkSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            void toggle(String id) {
              setSheet(() {
                if (selected.contains(id)) {
                  selected.remove(id);
                } else {
                  selected.add(id);
                }
              });
            }

            void selectAll() {
              setSheet(() {
                if (selected.length == tray.items.length) {
                  selected.clear();
                } else {
                  selected
                    ..clear()
                    ..addAll(tray.items.map((e) => e.id));
                }
              });
            }

            Widget thumbWidget(StoryTrayItem item) {
              final bytes = thumbs[item.id];
              if (bytes != null && bytes.isNotEmpty) {
                return Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                );
              }
              return Container(
                color: AppColors.darkCard,
                child: Icon(
                  item.isVideo ? Icons.videocam : Icons.image,
                  color: AppColors.textMuted,
                ),
              );
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: AppColors.darkCard,
                          backgroundImage: tray.profilePicUrl != null &&
                                  tray.profilePicUrl!.isNotEmpty
                              ? CachedNetworkImageProvider(tray.profilePicUrl!)
                              : null,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            tray.username,
                            style: GoogleFonts.poppins(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(ctx),
                          icon: const Icon(Icons.close,
                              color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(
                          'Download Options',
                          style: GoogleFonts.poppins(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: selectAll,
                          child: Text(
                            selected.length == tray.items.length
                                ? 'Deselect All'
                                : 'Select All',
                            style: GoogleFonts.poppins(
                              color: AppColors.accent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 148,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: tray.items.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 10),
                        itemBuilder: (_, i) {
                          final item = tray.items[i];
                          final isSelected = selected.contains(item.id);
                          return GestureDetector(
                            onTap: () => toggle(item.id),
                            child: SizedBox(
                              width: 100,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(10),
                                          child: thumbWidget(item),
                                        ),
                                        Positioned(
                                          top: 6,
                                          left: 6,
                                          child: Icon(
                                            isSelected
                                                ? Icons.check_circle
                                                : Icons.circle_outlined,
                                            color: isSelected
                                                ? AppColors.accent
                                                : Colors.white,
                                            size: 22,
                                          ),
                                        ),
                                        Positioned(
                                          top: 6,
                                          right: 6,
                                          child: Icon(
                                            item.isVideo
                                                ? Icons.videocam
                                                : Icons.image,
                                            color: Colors.white,
                                            size: 18,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    item.isVideo ? 'Video' : 'Photo',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.poppins(
                                      color: AppColors.textSecondary,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        onPressed: selected.isEmpty
                            ? null
                            : () async {
                                final toSave = tray.items
                                    .where((e) => selected.contains(e.id))
                                    .toList();
                                Navigator.pop(ctx);
                                await _downloadItems(tray.username, toSave);
                              },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: AppColors.darkCard,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          'Download (${selected.length})',
                          style: GoogleFonts.poppins(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'We never store your Instagram password.',
                      style: GoogleFonts.poppins(
                        color: AppColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _downloadItems(
    String username,
    List<StoryTrayItem> items,
  ) async {
    if (items.isEmpty) return;

    final progressNotifier = ValueNotifier<FileDownloadProgress?>(null);
    final messageNotifier = ValueNotifier<String>('Saving 1/${items.length}…');

    if (mounted) {
      DownloadProgressDialog.show(
        context,
        progressNotifier: progressNotifier,
        messageNotifier: messageNotifier,
      );
    }

    var ok = 0;
    var failed = 0;
    String? lastError;
    try {
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        progressNotifier.value = null;
        messageNotifier.value = 'Saving ${i + 1}/${items.length}…';

        // Each item is isolated: one bad slide (a stale/expired CDN url, a
        // truncated video) must not sink the rest of the selection — a user
        // who picked 10 slides expects the other 9 to still save.
        try {
          final isVideo = item.isVideo;
          final fileName = _downloadService.buildFileName(
            prefix: 'instasave_${username}_story',
            ext: isVideo ? 'mp4' : 'jpg',
            index: i + 1,
          );
          final saveType =
              isVideo ? MediaSaveType.video : MediaSaveType.image;

          DownloadResult result;
          final cleanUrl = item.mediaUrl.replaceAll('&amp;', '&');

          // Signed CDN: prefer plain GET with Referer (cookies often cause 403).
          final bytes = await _downloadCdnBytes(cleanUrl);
          if (bytes != null && bytes.isNotEmpty) {
            if (saveType == MediaSaveType.video &&
                !InstagramCdnUtils.looksLikeMp4(bytes)) {
              if (InstagramCdnUtils.looksLikeJpeg(bytes)) {
                result = await _downloadService.saveBytes(
                  bytes: bytes,
                  fileName: _downloadService.buildFileName(
                    prefix: 'instasave_${username}_story',
                    ext: 'jpg',
                    index: i + 1,
                  ),
                  saveType: MediaSaveType.image,
                );
              } else {
                throw Exception(
                  'Downloaded file is not a playable video. Try again.',
                );
              }
            } else {
              result = await _downloadService.saveBytes(
                bytes: bytes,
                fileName: fileName,
                saveType: saveType,
              );
            }
          } else {
            result = await _downloadService.downloadAndSave(
              url: cleanUrl,
              fileName: fileName,
              saveType: saveType,
              extraHeaders: {
                'Referer': (_pageUrl != null && _pageUrl!.startsWith('http'))
                    ? _pageUrl!
                    : 'https://www.instagram.com/',
              },
              onProgress: (p) => progressNotifier.value = p,
            );
          }

          final history = DownloadItem(
            id: '${DateTime.now().millisecondsSinceEpoch}_$i',
            fileName: result.savedPath.split('/').last,
            localPath: result.savedPath,
            thumbnailUrl: item.thumbnailUrl ?? item.mediaUrl,
            sourceUrl: _pageUrl ?? _startUrl,
            type: isVideo ? DownloadMediaType.video : DownloadMediaType.photo,
            quality: 'HD',
            fileSizeBytes: result.fileSizeBytes,
            downloadedAt: DateTime.now(),
            author: username,
            title: 'Instagram Story',
          );
          await ref.read(downloadHistoryProvider.notifier).add(history);
          ok++;
        } catch (e) {
          failed++;
          lastError = e.toString().replaceFirst('Exception: ', '');
          if (kDebugMode) {
            debugPrint('[Browser] story item $i download failed: $e');
          }
        }
      }

      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        final blocked = lastError != null &&
            (lastError.contains('blocked') || lastError.contains('403'));
        final String message;
        if (failed == 0) {
          message = 'Saved $ok story item(s) to gallery';
        } else if (ok == 0) {
          message = blocked
              ? 'Instagram blocked the download. Stay logged in and try again.'
              : 'Download failed: ${lastError ?? 'unknown error'}';
        } else {
          message = 'Saved $ok of ${items.length} — $failed failed'
              '${blocked ? ' (Instagram may be blocking some requests)' : ''}';
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), duration: const Duration(seconds: 5)),
        );
      }
    } finally {
      progressNotifier.dispose();
      messageNotifier.dispose();
    }
  }

  /// Fetch CDN media using the WebView's cookies (avoids Dio 403).
  Future<List<int>?> _fetchMediaBytesViaWebView(String url) async {
    final controller = _controller;
    if (controller == null) return null;
    try {
      final referer = (_pageUrl != null && _pageUrl!.startsWith('http'))
          ? _pageUrl!
          : 'https://www.instagram.com/';
      final result = await controller.callAsyncJavaScript(
        functionBody: '''
          const url = ${jsonEncode(url)};
          const referer = ${jsonEncode(referer)};
          try {
            const res = await fetch(url, {
              credentials: 'include',
              mode: 'cors',
              headers: {
                'Referer': referer,
                'Origin': 'https://www.instagram.com',
                'Accept': 'image/avif,image/webp,image/apng,image/*,video/*,*/*;q=0.8'
              }
            });
            if (!res.ok) return { error: res.status };
            const buf = await res.arrayBuffer();
            const bytes = new Uint8Array(buf);
            if (bytes.length < 64) return { error: 'too_small' };
            let binary = '';
            const chunk = 0x8000;
            for (let i = 0; i < bytes.length; i += chunk) {
              binary += String.fromCharCode.apply(
                null,
                bytes.subarray(i, Math.min(i + chunk, bytes.length))
              );
            }
            return { b64: btoa(binary), size: bytes.length };
          } catch (e) {
            return { error: String(e) };
          }
        ''',
      );
      final value = result?.value;
      if (value is! Map) return null;
      if (value['error'] != null) {
        if (kDebugMode) {
          debugPrint('[Browser] webview fetch error: ${value['error']}');
        }
        return null;
      }
      final b64 = value['b64']?.toString();
      if (b64 == null || b64.isEmpty) return null;
      return base64Decode(b64);
    } catch (e) {
      if (kDebugMode) debugPrint('[Browser] webview media fetch failed: $e');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      body: SafeArea(
        child: Column(
          children: [
            _BrowserChrome(
              urlController: _urlController,
              loading: _loading,
              canGoBack: _canGoBack,
              loggedIn: _loggedIn,
              onClose: () => Navigator.of(context).pop(),
              onBack: () async {
                await _controller?.goBack();
                await _updateNav();
              },
              onRefresh: _reload,
              onHome: _goHome,
              onSubmitUrl: (value) {
                var url = value.trim();
                if (url.isEmpty) return;
                if (!url.startsWith('http')) url = 'https://$url';
                _controller?.loadUrl(
                  urlRequest: URLRequest(url: WebUri(url)),
                );
              },
              onWhyLogin: () async {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool(_prefsWhyLoginKey, false);
                await _maybeShowWhyLogin();
              },
            ),
            if (_showTipBanner)
              _TipBanner(
                onHowTo: () {
                  setState(() => _showTipBanner = false);
                  _maybeShowWhyLogin();
                },
                onClose: () => setState(() => _showTipBanner = false),
              ),
            if (_loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: Stack(
                children: [
                  InAppWebView(
                    initialUrlRequest: URLRequest(
                      url: WebUri(_startUrl),
                      headers: const {
                        'User-Agent': InstagramCdnUtils.mobileUserAgent,
                      },
                    ),
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      mediaPlaybackRequiresUserGesture: false,
                      allowsInlineMediaPlayback: true,
                      sharedCookiesEnabled: true,
                      thirdPartyCookiesEnabled: true,
                      domStorageEnabled: true,
                      databaseEnabled: true,
                      useShouldOverrideUrlLoading: true,
                      useShouldInterceptRequest: true,
                      supportMultipleWindows: false,
                      userAgent: InstagramCdnUtils.mobileUserAgent,
                    ),
                    shouldInterceptRequest: (controller, request) async {
                      final url = request.url.toString();
                      // Capture while story UI is open OR URL path says stories.
                      _rememberStoryUrl(url, force: _onStoryPage);
                      return null;
                    },
                    shouldOverrideUrlLoading:
                        (controller, navigationAction) async {
                      final uri = navigationAction.request.url;
                      final url = uri?.toString() ?? '';
                      final scheme = (uri?.scheme ?? '').toLowerCase();

                      // Stay on the web — block App Store / intent / custom schemes.
                      // Instagram's "Open Instagram" button uses intent:// /
                      // instagram:// — previously we cancelled with no feedback.
                      // Redirect to web login so stories + HD DP session work.
                      if (scheme == 'http' || scheme == 'https') {
                        if (url.contains('apps.apple.com') ||
                            url.contains('play.google.com/store')) {
                          await _loadWebLogin(controller);
                          return NavigationActionPolicy.CANCEL;
                        }
                        return NavigationActionPolicy.ALLOW;
                      }
                      if (kDebugMode) {
                        debugPrint(
                          '[Browser] app deep-link → web login: $url',
                        );
                      }
                      await _loadWebLogin(controller);
                      return NavigationActionPolicy.CANCEL;
                    },
                    onReceivedError: (controller, request, error) async {
                      final failing = request.url.toString();
                      if (failing.contains('itms-') ||
                          failing.contains('market:') ||
                          failing.contains('intent:') ||
                          failing.contains('instagram://')) {
                        await _loadWebLogin(controller);
                      }
                    },
                    onWebViewCreated: (controller) {
                      _controller = controller;
                      controller.addJavaScriptHandler(
                        handlerName: 'onStoryMediaUrl',
                        callback: (args) {
                          if (args.isEmpty) return null;
                          final u = args.first?.toString();
                          if (u != null) _rememberStoryUrl(u);
                          return null;
                        },
                      );
                      controller.addJavaScriptHandler(
                        handlerName: 'onQsHookDiag',
                        callback: (args) {
                          if (args.isEmpty) return null;
                          print('[Browser] qsHook ${args.first}');
                          return null;
                        },
                      );
                      controller.addJavaScriptHandler(
                        handlerName: 'onStoryApiPayload',
                        callback: (args) {
                          if (args.isEmpty) return null;
                          final raw = args.first?.toString();
                          if (raw == null || raw.length < 40) return null;
                          try {
                            final decoded = jsonDecode(raw);
                            if (decoded is Map) {
                              final map = Map<String, dynamic>.from(
                                decoded.map(
                                  (k, v) => MapEntry(k.toString(), v),
                                ),
                              );
                              final keys = map.keys.take(12).join(',');
                              print(
                                '[Browser] qsHook payload keys=[$keys] '
                                'storyShape=${_isStoryApiPayload(map)} len=${raw.length}',
                              );
                              // Ignore feed / timeline GraphQL dumps.
                              if (_isStoryApiPayload(map)) {
                                _capturedTrayPayload = map;
                              }
                            }
                          } catch (_) {}
                          return null;
                        },
                      );
                    },
                    onConsoleMessage: (controller, consoleMessage) {
                      final msg = consoleMessage.message;
                      if (msg.contains('qsHook')) {
                        print('[Browser] $msg');
                      }
                    },
                    onLoadStart: (controller, url) {
                      setState(() => _loading = true);
                      _syncPageFlags(url?.toString());
                    },
                    onUpdateVisitedHistory:
                        (controller, url, androidIsReload) async {
                      _syncPageFlags(url?.toString());
                      await _updateNav();
                      await _refreshSessionFlag();
                      await _maybeAutoTriggerDownload();
                    },
                    onLoadStop: (controller, url) async {
                      if (mounted) setState(() => _loading = false);
                      _syncPageFlags(url?.toString());
                      await _updateNav();
                      await _refreshSessionFlag();
                      await _refreshStoryUiFlag(controller);
                      await _installStoryCaptureHooks(controller);
                      await _hijackOpenInstagramButtons(controller);
                      await _maybeAutoTriggerDownload();
                    },
                  ),
                  if (_onStoryPage || _loggedIn)
                    Positioned(
                      left: 12,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _DownloadFab(
                          loading: _fetchingTray,
                          onPressed: _onDownloadFabPressed,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BrowserChrome extends StatelessWidget {
  const _BrowserChrome({
    required this.urlController,
    required this.loading,
    required this.canGoBack,
    required this.loggedIn,
    required this.onClose,
    required this.onBack,
    required this.onRefresh,
    required this.onHome,
    required this.onSubmitUrl,
    required this.onWhyLogin,
  });

  final TextEditingController urlController;
  final bool loading;
  final bool canGoBack;
  final bool loggedIn;
  final VoidCallback onClose;
  final VoidCallback onBack;
  final VoidCallback onRefresh;
  final VoidCallback onHome;
  final ValueChanged<String> onSubmitUrl;
  final VoidCallback onWhyLogin;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.darkSurface,
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Close',
            onPressed: onClose,
            icon: const Icon(Icons.close, color: AppColors.textPrimary),
          ),
          if (canGoBack)
            IconButton(
              tooltip: 'Back',
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_ios_new,
                  size: 16, color: AppColors.textPrimary),
            ),
          Expanded(
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: AppColors.darkInput,
                borderRadius: BorderRadius.circular(18),
              ),
              alignment: Alignment.centerLeft,
              child: TextField(
                controller: urlController,
                style: GoogleFonts.poppins(
                  color: AppColors.textPrimary,
                  fontSize: 12,
                ),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                maxLines: 1,
                textInputAction: TextInputAction.go,
                onSubmitted: onSubmitUrl,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: onRefresh,
            icon: loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh, color: AppColors.textPrimary),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: AppColors.textPrimary),
            color: AppColors.darkCard,
            onSelected: (v) {
              if (v == 'why') onWhyLogin();
              if (v == 'home') onHome();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'home',
                child: Text(
                  'Instagram home',
                  style: GoogleFonts.poppins(color: AppColors.textPrimary),
                ),
              ),
              PopupMenuItem(
                value: 'why',
                child: Text(
                  'Why login?',
                  style: GoogleFonts.poppins(color: AppColors.textPrimary),
                ),
              ),
              PopupMenuItem(
                enabled: false,
                child: Text(
                  loggedIn ? 'Logged in' : 'Not logged in',
                  style: GoogleFonts.poppins(
                    color: loggedIn
                        ? const Color(0xFF81C784)
                        : AppColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TipBanner extends StatelessWidget {
  const _TipBanner({required this.onHowTo, required this.onClose});

  final VoidCallback onHowTo;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: AppColors.darkCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.accent.withOpacity(0.7)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Tap Log in / Sign up on this page (not “Open Instagram”). After you’re logged in, open a story and tap the pink download button. We never store your password.',
                  style: GoogleFonts.poppins(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: onHowTo,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.accent,
                    side: const BorderSide(color: AppColors.accent),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    'How to Download?',
                    style: GoogleFonts.poppins(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close, size: 18, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _DownloadFab extends StatelessWidget {
  const _DownloadFab({required this.onPressed, required this.loading});

  final VoidCallback onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.accent,
      shape: const CircleBorder(),
      elevation: 6,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: loading ? null : onPressed,
        child: SizedBox(
          width: 54,
          height: 54,
          child: Center(
            child: loading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.download_rounded,
                    color: Colors.white, size: 28),
          ),
        ),
      ),
    );
  }
}

class _WhyLoginDialog extends StatelessWidget {
  const _WhyLoginDialog({
    required this.onGotIt,
    required this.onPrivacy,
  });

  final VoidCallback onGotIt;
  final VoidCallback onPrivacy;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.darkSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 12, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const CircleAvatar(
                  radius: 16,
                  backgroundColor: Color(0xFF1E88E5),
                  child: Icon(Icons.lock, color: Colors.white, size: 18),
                ),
                const SizedBox(width: 10),
                Text(
                  'Why login?',
                  style: GoogleFonts.poppins(
                    color: const Color(0xFF64B5F6),
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: onGotIt,
                  icon: const Icon(Icons.close, color: AppColors.textMuted),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Login required',
              style: GoogleFonts.poppins(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '1. Due to Instagram updates, you need to log in to download stories.\n'
              '2. You log into Instagram’s official website. We never store your password.',
              style: GoogleFonts.poppins(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'After logging in',
              style: GoogleFonts.poppins(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '1. Download Posts / Reels / Stories available to your account.\n'
              '2. You only need to log in once — your session stays in the app browser.\n'
              '3. You can log out anytime on Instagram.',
              style: GoogleFonts.poppins(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton(
                onPressed: onGotIt,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  'Got It',
                  style: GoogleFonts.poppins(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: TextButton(
                onPressed: onPrivacy,
                child: Text(
                  'Privacy Policy',
                  style: GoogleFonts.poppins(
                    color: AppColors.textMuted,
                    decoration: TextDecoration.underline,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
