/// Shared helpers for validating Instagram CDN media URLs.
class InstagramCdnUtils {
  InstagramCdnUtils._();

  static const mobileUserAgent =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  /// Prefer Android UA in WebView so Instagram does not redirect to itms-apps://
  static const androidWebUserAgent = mobileUserAgent;

  static const downloadHeaders = <String, String>{
    'User-Agent': mobileUserAgent,
    'Accept': '*/*',
    'Accept-Language': 'en-US,en;q=0.9',
    'Referer': 'https://www.instagram.com/',
    'Origin': 'https://www.instagram.com',
  };

  static bool isInstagramCdn(String url) {
    final lower = url.toLowerCase();
    return lower.contains('cdninstagram.com') ||
        lower.contains('fbcdn.net') ||
        lower.contains('instagram.f');
  }

  static bool isLikelyMp4Video(String url) {
    final lower = url.toLowerCase();
    if (!isInstagramCdn(lower)) return false;
    if (lower.startsWith('blob:')) return false;
    if (lower.contains('.m3u8') || lower.contains('application/x-mpegurl')) {
      return false;
    }
    // Prefer real progressive MP4 files.
    if (lower.contains('.mp4')) return true;
    // Common Instagram video path markers (without mistaking image URLs).
    if (lower.contains('/v/t50.') ||
        lower.contains('/v/t16.') ||
        lower.contains('/o1/v/') ||
        lower.contains('video_dashinit') ||
        (lower.contains('video') &&
            (lower.contains('stp=') || lower.contains('efg=')))) {
      return !isLikelyImage(lower);
    }
    return false;
  }

  static bool isLikelyImage(String url) {
    final lower = url.toLowerCase();
    if (!isInstagramCdn(lower)) return false;
    if (lower.contains('profile_pic')) return false;
    if (RegExp(r's\d{2,4}x\d{2,4}').hasMatch(lower) &&
        !_hasDecentImageSize(lower)) {
      return false;
    }
    // Skip tiny thumbs / UI chrome.
    if (lower.contains('s150x150') ||
        lower.contains('s240x240') ||
        lower.contains('s320x320') ||
        lower.contains('/rsrc.php') ||
        lower.contains('static.cdninstagram') ||
        lower.contains('instagram.com/static')) {
      return false;
    }
    return lower.contains('.jpg') ||
        lower.contains('.jpeg') ||
        lower.contains('.webp') ||
        lower.contains('t51.') ||
        lower.contains('e35') ||
        lower.contains('e15') ||
        lower.contains('stp=dst-jpg') ||
        lower.contains('stp=dst-webp');
  }

  static bool _hasDecentImageSize(String lower) {
    // Prefer mid/high res dimension tokens Instagram embeds in CDN paths.
    return lower.contains('s640x640') ||
        lower.contains('s750x750') ||
        lower.contains('s1080x1080') ||
        lower.contains('s1440x1440') ||
        RegExp(r'[?&]stp=[^&]*s\d{3,}').hasMatch(lower);
  }

  /// Higher score = better quality candidate.
  static int imageQualityScore(String url) {
    final lower = url.toLowerCase();
    var score = url.length;
    if (lower.contains('s1440x1440') || lower.contains('1080')) score += 5000;
    if (lower.contains('s1080x1080') || lower.contains('s750x750')) {
      score += 3000;
    }
    if (lower.contains('s640x640')) score += 1500;
    if (lower.contains('e35') || lower.contains('e15')) score += 400;
    if (lower.contains('profile_pic') || lower.contains('s150x150')) {
      score -= 10000;
    }
    if (lower.contains('s240x240') || lower.contains('s320x320')) {
      score -= 5000;
    }
    return score;
  }

  static int videoQualityScore(String url) {
    final lower = url.toLowerCase();
    var score = url.length;
    if (lower.contains('.mp4')) score += 10000;
    if (lower.contains('720') || lower.contains('hd')) score += 500;
    if (lower.contains('1080')) score += 1000;
    if (lower.contains('byterange')) score -= 2000;
    return score;
  }

  static String? pickBestVideo(List<String> urls) {
    final valid = urls.where(isLikelyMp4Video).toList();
    if (valid.isEmpty) return null;
    valid.sort((a, b) => videoQualityScore(b).compareTo(videoQualityScore(a)));
    return valid.first;
  }

  static String? pickBestImage(List<String> urls) {
    final valid = urls.where(isLikelyImage).toList();
    if (valid.isEmpty) return null;
    valid.sort((a, b) => imageQualityScore(b).compareTo(imageQualityScore(a)));
    return valid.first;
  }

  static String? storyMediaIdFromUrl(String storyUrl) {
    final match = RegExp(
      r'/stories/[^/]+/(\d+)',
      caseSensitive: false,
    ).firstMatch(storyUrl);
    return match?.group(1);
  }

  /// MP4 files start with ftyp box near the start; JPEGs with FF D8.
  static bool looksLikeMp4(List<int> bytes) {
    if (bytes.length < 12) return false;
    // ....ftyp
    for (var i = 0; i < 8 && i + 3 < bytes.length; i++) {
      if (bytes[i] == 0x66 &&
          bytes[i + 1] == 0x74 &&
          bytes[i + 2] == 0x79 &&
          bytes[i + 3] == 0x70) {
        return true;
      }
    }
    return false;
  }

  static bool looksLikeJpeg(List<int> bytes) {
    return bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF;
  }

  static bool looksLikeHtml(List<int> bytes) {
    if (bytes.length < 15) return false;
    final head = String.fromCharCodes(
      bytes.take(64).where((b) => b >= 9 && b < 127),
    ).toLowerCase();
    return head.contains('<!doctype') ||
        head.contains('<html') ||
        head.contains('<head');
  }
}
