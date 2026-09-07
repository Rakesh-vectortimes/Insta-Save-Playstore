/// One item in a user's Instagram story tray.
class StoryTrayItem {
  const StoryTrayItem({
    required this.id,
    required this.mediaUrl,
    required this.mediaType,
    this.thumbnailUrl,
    this.caption,
    this.width,
    this.height,
  });

  final String id;
  final String mediaUrl;
  final String mediaType; // 'video' | 'image'
  final String? thumbnailUrl;
  final String? caption;
  final int? width;
  final int? height;

  bool get isVideo => mediaType == 'video';
}

class StoryTrayResult {
  const StoryTrayResult({
    required this.username,
    this.profilePicUrl,
    required this.items,
  });

  final String username;
  final String? profilePicUrl;
  final List<StoryTrayItem> items;
}
