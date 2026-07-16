import 'carousel_item.dart';

enum PostType { image, video, carousel }

class PostResult {
  const PostResult({
    required this.type,
    required this.title,
    required this.author,
    this.url,
    this.thumbnail,
    this.ext,
    this.count,
    this.items = const [],
  });

  final PostType type;
  final String title;
  final String author;
  final String? url;
  final String? thumbnail;
  final String? ext;
  final int? count;
  final List<CarouselItem> items;

  bool get isCarousel => type == PostType.carousel;

  factory PostResult.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? 'image';

    if (typeStr == 'carousel') {
      return PostResult(
        type: PostType.carousel,
        title: json['title'] as String? ?? 'Instagram Post',
        author: json['author'] as String? ?? '',
        count: (json['count'] as num?)?.toInt(),
        items: (json['items'] as List<dynamic>?)
                ?.map((e) => CarouselItem.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );
    }

    return PostResult(
      type: typeStr == 'video' ? PostType.video : PostType.image,
      title: json['title'] as String? ?? 'Instagram Post',
      author: json['author'] as String? ?? '',
      url: json['url'] as String?,
      thumbnail: json['thumbnail'] as String?,
      ext: json['ext'] as String?,
    );
  }
}
