class InstagramShortcode {
  static final _pattern = RegExp(
    r'instagram\.com/(?:p|reel|reels|tv)/([A-Za-z0-9_-]+)',
    caseSensitive: false,
  );

  static String? fromUrl(String url) {
    return _pattern.firstMatch(url.trim())?.group(1);
  }
}
