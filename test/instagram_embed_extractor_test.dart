import 'package:flutter_test/flutter_test.dart';
import 'package:instasave/services/instagram_embed_extractor.dart';

void main() {
  group('InstagramEmbedExtractor', () {
    test('throws when contextJSON is null', () {
      const html = '''
requireLazy(["TimeSliceImpl","ServerJS"],function(TimeSlice,ServerJS){var s=(new ServerJS());s.handle({"define":[["PolarisEmbedPost",[],{"isRichEmbed":false,"isSidecar":false,"isGuideEmbed":false,"isProfileEmbed":false,"contextJSON":null}]],["NavigationMetrics","setPage",[],[]]});});
''';

      expect(
        () => InstagramEmbedExtractor.parseHtml(html),
        throwsA(isA<EmbedExtractionException>()),
      );
    });

    test('parses modern single-video payload', () {
      const context = '''
{"video_duration":12.5,"product_type":"clips","user":{"username":"creator"},"caption":{"text":"Test reel"},"video_versions":[{"url":"https://cdn.example/video_720.mp4","width":720,"height":1280},{"url":"https://cdn.example/video_480.mp4","width":480,"height":854}],"image_versions2":{"candidates":[{"url":"https://cdn.example/thumb.jpg","width":640,"height":640}]}}
''';

      final html = _wrapContext(context);
      final media = InstagramEmbedExtractor.parseHtml(html);

      expect(media.isVideo, isTrue);
      expect(media.isReel, isTrue);
      expect(media.author, 'creator');
      expect(media.title, 'Test reel');
      expect(media.items.first.url, 'https://cdn.example/video_720.mp4');
      expect(media.duration, 12.5);
    });

    test('parses modern carousel payload', () {
      const context = '''
{"user":{"username":"creator"},"caption":{"text":"Carousel post"},"carousel_media":[{"image_versions2":{"candidates":[{"url":"https://cdn.example/1.jpg","width":1080,"height":1080}]}},{"video_versions":[{"url":"https://cdn.example/2.mp4","width":720,"height":1280}],"image_versions2":{"candidates":[{"url":"https://cdn.example/2.jpg","width":720,"height":1280}]}}]}
''';

      final html = _wrapContext(context);
      final media = InstagramEmbedExtractor.parseHtml(html);

      expect(media.isCarousel, isTrue);
      expect(media.items.length, 2);
      expect(media.items[0].type, 'image');
      expect(media.items[1].type, 'video');
    });

    test('parses legacy shortcode_media payload', () {
      const context = '''
{"shortcode_media":{"owner":{"username":"legacy_user"},"edge_media_to_caption":{"edges":[{"node":{"text":"Legacy caption"}}]},"is_video":true,"video_url":"https://cdn.example/legacy.mp4","display_url":"https://cdn.example/legacy.jpg","video_duration":8.0,"product_type":"clips"}}
''';

      final html = _wrapContext(context);
      final media = InstagramEmbedExtractor.parseHtml(html);

      expect(media.isVideo, isTrue);
      expect(media.author, 'legacy_user');
      expect(media.items.first.url, 'https://cdn.example/legacy.mp4');
    });
  });
}

String _wrapContext(String contextJson) {
  final escaped = contextJson
      .replaceAll('\\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n');
  return '"init",[],[{"isRichEmbed":false,"isSidecar":false,"isGuideEmbed":false,"isProfileEmbed":false,"contextJSON":"$escaped"}]],["NavigationMetrics"';
}
