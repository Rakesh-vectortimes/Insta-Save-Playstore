import 'constants.dart';

enum InstagramUrlType {
  reel,
  post,
  story,
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
        errorMessage: AppConstants.storyNotSupportedMessage,
      );
    }

    if (lower.contains('/reel/') || lower.contains('/reels/')) {
      return UrlDetectionResult(
        type: InstagramUrlType.reel,
        normalizedUrl: normalized,
      );
    }

    if (lower.contains('/p/')) {
      return UrlDetectionResult(
        type: InstagramUrlType.post,
        normalizedUrl: normalized,
      );
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

  static String sanitizeUsername(String input) {
    return input.trim().replaceFirst(RegExp(r'^@+'), '');
  }

  /// Pulls the first Instagram post/reel URL out of arbitrary clipboard text.
  static String? extractInstagramUrl(String text) {
    final match = RegExp(
      r'https?://(?:www\.)?instagram\.com/(?:reel|reels|p)/[A-Za-z0-9_-]+/?',
      caseSensitive: false,
    ).firstMatch(text);
    if (match != null) return match.group(0);

    final loose = RegExp(
      r'(?:www\.)?instagram\.com/(?:reel|reels|p)/[A-Za-z0-9_-]+/?',
      caseSensitive: false,
    ).firstMatch(text);
    if (loose != null) return 'https://${loose.group(0)}';

    return null;
  }
}
