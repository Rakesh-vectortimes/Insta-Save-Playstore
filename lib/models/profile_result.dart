class ProfileResult {
  const ProfileResult({
    required this.username,
    required this.fullName,
    required this.dpUrl,
    required this.isPrivate,
    required this.followers,
    this.dpSize,
    this.lowQuality = false,
    this.upscaleAvailable = false,
    this.upscaleFactor,
    this.estimatedUpscaledSize,
    this.upscaleNote,
  });

  final String username;
  final String fullName;
  final String dpUrl;
  final bool isPrivate;
  final int followers;
  final int? dpSize;
  final bool lowQuality;
  final bool upscaleAvailable;
  final int? upscaleFactor;
  final int? estimatedUpscaledSize;
  final String? upscaleNote;

  factory ProfileResult.fromJson(Map<String, dynamic> json) {
    return ProfileResult(
      username: json['username'] as String? ?? '',
      fullName: json['fullName'] as String? ?? '',
      dpUrl: json['dpUrl'] as String? ?? '',
      isPrivate: json['isPrivate'] as bool? ?? false,
      followers: (json['followers'] as num?)?.toInt() ?? 0,
      dpSize: (json['dpSize'] as num?)?.toInt(),
      lowQuality: json['lowQuality'] as bool? ?? false,
      upscaleAvailable: json['upscaleAvailable'] as bool? ?? false,
      upscaleFactor: (json['upscaleFactor'] as num?)?.toInt(),
      estimatedUpscaledSize: (json['estimatedUpscaledSize'] as num?)?.toInt(),
      upscaleNote: json['upscaleNote'] as String?,
    );
  }
}

class ProfilePictureDownloadResult {
  const ProfilePictureDownloadResult({
    required this.bytes,
    required this.wasUpscaled,
  });

  final List<int> bytes;
  final bool wasUpscaled;
}
