import 'constants.dart';

enum InstagramUrlType {
  reel,
  post,
  story,
  profile,
  invalid,
}

class UrlDetectionResult {
  const UrlDetectionResult({
    required this.type,
    this.normalizedUrl,
    this.errorMessage,
  });

  final InstagramUrlType type;
  final String? normalizedUrl;
  final String? errorMessage;

  bool get isError => errorMessage != null;
}

class UrlDetector {
  static final _instagramHostPattern = RegExp(
    r'(?:https?://)?(?:www\.)?instagram\.com',
    caseSensitive: false,
  );

  static UrlDetectionResult detect(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return const UrlDetectionResult(
        type: InstagramUrlType.invalid,
        errorMessage: AppConstants.invalidUrlMessage,
      );
    }

    final normalized = _normalizeUrl(trimmed);

    if (!_instagramHostPattern.hasMatch(normalized)) {
      return const UrlDetectionResult(
        type: InstagramUrlType.invalid,
        errorMessage: AppConstants.invalidUrlMessage,
      );
    }

    final lower = normalized.toLowerCase();

    if (lower.contains('/stories/')) {
      return UrlDetectionResult(
        type: InstagramUrlType.story,
        normalizedUrl: normalized,
      );
    }

    if (lower.contains('/reel/') || lower.contains('/reels/')) {
      return UrlDetectionResult(
        type: InstagramUrlType.reel,
        normalizedUrl: normalized,
      );
    }

    if (lower.contains('/p/') || lower.contains('/tv/')) {
      return UrlDetectionResult(
        type: InstagramUrlType.post,
        normalizedUrl: normalized,
      );
    }

    final profileMatch = RegExp(
      r'instagram\.com/([A-Za-z0-9._]+)/?$',
      caseSensitive: false,
    ).firstMatch(normalized);
    if (profileMatch != null) {
      final handle = profileMatch.group(1)!.toLowerCase();
      const reserved = {
        'reel',
        'reels',
        'p',
        'tv',
        'stories',
        'accounts',
        'explore',
        'direct',
        'about',
        'legal',
      };
      if (!reserved.contains(handle)) {
        return UrlDetectionResult(
          type: InstagramUrlType.profile,
          normalizedUrl: normalized,
        );
      }
    }

    return const UrlDetectionResult(
      type: InstagramUrlType.invalid,
      errorMessage: AppConstants.invalidUrlMessage,
    );
  }

  static String _normalizeUrl(String input) {
    var url = input.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    try {
      final uri = Uri.parse(url);
      return uri.replace(query: null, fragment: null).toString();
    } catch (_) {
      return url;
    }
  }

  /// Normalizes pasted Instagram usernames.
  /// Accepts `@user`, profile URLs, and strips invalid characters/spaces.
  static String sanitizeUsername(String input) {
    var value = input.trim();
    if (value.isEmpty) return '';

    final urlMatch = RegExp(
      r'(?:https?://)?(?:www\.)?instagram\.com/([A-Za-z0-9._]+)/?',
      caseSensitive: false,
    ).firstMatch(value);
    if (urlMatch != null) {
      value = urlMatch.group(1)!;
    }

    value = value.replaceFirst(RegExp(r'^@+'), '');
    value = value.split(RegExp(r'[/?#]')).first;
    value = value.replaceAll(RegExp(r'\s+'), '');
    return value;
  }

  static bool isValidUsername(String username) {
    return RegExp(r'^[A-Za-z0-9._]{1,30}$').hasMatch(username);
  }

  /// Pulls the first Instagram post/reel/story URL out of arbitrary clipboard text.
  static String? extractInstagramUrl(String text) {
    final match = RegExp(
      r'https?://(?:www\.)?instagram\.com/(?:reel|reels|p|tv|stories/[A-Za-z0-9._]+)/[A-Za-z0-9_-]+/?',
      caseSensitive: false,
    ).firstMatch(text);
    if (match != null) return match.group(0);

    final loose = RegExp(
      r'(?:www\.)?instagram\.com/(?:reel|reels|p|tv|stories/[A-Za-z0-9._]+)/[A-Za-z0-9_-]+/?',
      caseSensitive: false,
    ).firstMatch(text);
    if (loose != null) return 'https://${loose.group(0)}';

    return null;
  }
}
