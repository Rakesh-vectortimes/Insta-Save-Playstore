class ReelDownloadOption {
  const ReelDownloadOption({
    required this.format,
    required this.quality,
    required this.label,
    required this.url,
  });

  final String format;
  final int quality;
  final String label;
  final String url;

  factory ReelDownloadOption.fromJson(Map<String, dynamic> json) {
    return ReelDownloadOption(
      format: json['format'] as String? ?? 'mp4',
      quality: (json['quality'] as num?)?.toInt() ?? 720,
      label: json['label'] as String? ?? '',
      url: json['url'] as String? ?? '',
    );
  }
}

class ReelResult {
  const ReelResult({
    required this.title,
    required this.thumbnail,
    required this.duration,
    required this.source,
    required this.formats,
    required this.qualities,
    required this.downloadUrl,
    required this.downloads,
    required this.originalUrl,
  });

  final String title;
  final String? thumbnail;
  final double? duration;
  final String source;
  final List<String> formats;
  final List<String> qualities;
  final String downloadUrl;
  final List<ReelDownloadOption> downloads;
  final String originalUrl;

  factory ReelResult.fromJson(Map<String, dynamic> json, String originalUrl) {
    return ReelResult(
      title: json['title'] as String? ?? 'Instagram Reel',
      thumbnail: json['thumbnail'] as String?,
      duration: (json['duration'] as num?)?.toDouble(),
      source: json['source'] as String? ?? 'scraper',
      formats: (json['formats'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const ['mp4'],
      qualities: (json['qualities'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const ['720p'],
      downloadUrl: json['downloadUrl'] as String? ?? '',
      downloads: (json['downloads'] as List<dynamic>?)
              ?.map((e) => ReelDownloadOption.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      originalUrl: originalUrl,
    );
  }

  ReelDownloadOption? findDownload({
    required String format,
    required int quality,
  }) {
    for (final option in downloads) {
      if (option.format == format && option.quality == quality) {
        return option;
      }
    }
    return downloads.isNotEmpty ? downloads.first : null;
  }

  List<int> availableQualitiesForFormat(String format) {
    return downloads
        .where((d) => d.format == format)
        .map((d) => d.quality)
        .toSet()
        .toList()
      ..sort();
  }
}
