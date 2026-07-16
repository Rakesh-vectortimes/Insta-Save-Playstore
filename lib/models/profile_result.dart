class ProfileResult {
  const ProfileResult({
    required this.username,
    required this.fullName,
    required this.dpUrl,
    required this.isPrivate,
    required this.followers,
  });

  final String username;
  final String fullName;
  final String dpUrl;
  final bool isPrivate;
  final int followers;

  factory ProfileResult.fromJson(Map<String, dynamic> json) {
    return ProfileResult(
      username: json['username'] as String? ?? '',
      fullName: json['fullName'] as String? ?? '',
      dpUrl: json['dpUrl'] as String? ?? '',
      isPrivate: json['isPrivate'] as bool? ?? false,
      followers: (json['followers'] as num?)?.toInt() ?? 0,
    );
  }
}
