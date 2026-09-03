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
    this.source,
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
  final String? source;

  factory ProfileResult.fromJson(Map<String, dynamic> json) {
    return ProfileResult(
      username: (json['username'] ?? json['userName'] ?? '') as String? ?? '',
      fullName: (json['fullName'] ?? json['full_name'] ?? '') as String? ?? '',
      dpUrl: (json['dpUrl'] ??
              json['dp_url'] ??
              json['profilePicUrl'] ??
              json['profile_pic_url'] ??
              '') as String? ??
          '',
      isPrivate: json['isPrivate'] as bool? ??
          json['is_private'] as bool? ??
          false,
      followers: (json['followers'] as num?)?.toInt() ??
          (json['follower_count'] as num?)?.toInt() ??
          0,
      dpSize: (json['dpSize'] as num?)?.toInt() ??
          (json['dp_size'] as num?)?.toInt(),
      lowQuality: json['lowQuality'] as bool? ??
          json['low_quality'] as bool? ??
          false,
      upscaleAvailable: json['upscaleAvailable'] as bool? ??
          json['upscale_available'] as bool? ??
          false,
      upscaleFactor: (json['upscaleFactor'] as num?)?.toInt() ??
          (json['upscale_factor'] as num?)?.toInt(),
      estimatedUpscaledSize: (json['estimatedUpscaledSize'] as num?)?.toInt() ??
          (json['estimated_upscaled_size'] as num?)?.toInt(),
      upscaleNote: json['upscaleNote'] as String? ??
          json['upscale_note'] as String?,
      source: json['source'] as String?,
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
