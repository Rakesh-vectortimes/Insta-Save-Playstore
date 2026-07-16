class CarouselItem {
  const CarouselItem({
    required this.index,
    required this.type,
    required this.url,
    required this.ext,
    this.thumbnail,
  });

  final int index;
  final String type;
  final String url;
  final String ext;
  final String? thumbnail;

  bool get isVideo => type == 'video';

  factory CarouselItem.fromJson(Map<String, dynamic> json) {
    return CarouselItem(
      index: (json['index'] as num?)?.toInt() ?? 0,
      type: json['type'] as String? ?? 'image',
      url: json['url'] as String? ?? '',
      ext: json['ext'] as String? ?? 'jpg',
      thumbnail: json['thumbnail'] as String?,
    );
  }
}
