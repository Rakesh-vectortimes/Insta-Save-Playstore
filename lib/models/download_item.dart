enum DownloadMediaType { video, photo, music, zip }

class DownloadItem {
  const DownloadItem({
    required this.id,
    required this.fileName,
    required this.localPath,
    required this.thumbnailUrl,
    required this.sourceUrl,
    required this.type,
    required this.quality,
    required this.fileSizeBytes,
    required this.downloadedAt,
    this.author,
    this.title,
  });

  final String id;
  final String fileName;
  final String localPath;
  final String thumbnailUrl;
  final String sourceUrl;
  final DownloadMediaType type;
  final String quality;
  final int fileSizeBytes;
  final DateTime downloadedAt;
  final String? author;
  final String? title;

  String get fileSizeLabel {
    if (fileSizeBytes < 1024) return '${fileSizeBytes}B';
    if (fileSizeBytes < 1024 * 1024) {
      return '${(fileSizeBytes / 1024).toStringAsFixed(1)}KB';
    }
    return '${(fileSizeBytes / (1024 * 1024)).toStringAsFixed(2)}MB';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'localPath': localPath,
        'thumbnailUrl': thumbnailUrl,
        'sourceUrl': sourceUrl,
        'type': type.name,
        'quality': quality,
        'fileSizeBytes': fileSizeBytes,
        'downloadedAt': downloadedAt.toIso8601String(),
        'author': author,
        'title': title,
      };

  factory DownloadItem.fromJson(Map<String, dynamic> json) {
    return DownloadItem(
      id: json['id'] as String,
      fileName: json['fileName'] as String,
      localPath: json['localPath'] as String,
      thumbnailUrl: json['thumbnailUrl'] as String? ?? '',
      sourceUrl: json['sourceUrl'] as String? ?? '',
      type: DownloadMediaType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => DownloadMediaType.video,
      ),
      quality: json['quality'] as String? ?? 'HD',
      fileSizeBytes: json['fileSizeBytes'] as int? ?? 0,
      downloadedAt: DateTime.parse(json['downloadedAt'] as String),
      author: json['author'] as String?,
      title: json['title'] as String?,
    );
  }

  DownloadItem copyWith({
    String? localPath,
    int? fileSizeBytes,
  }) {
    return DownloadItem(
      id: id,
      fileName: fileName,
      localPath: localPath ?? this.localPath,
      thumbnailUrl: thumbnailUrl,
      sourceUrl: sourceUrl,
      type: type,
      quality: quality,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      downloadedAt: downloadedAt,
      author: author,
      title: title,
    );
  }
}

class DownloadResult {
  const DownloadResult({
    required this.savedPath,
    required this.fileSizeBytes,
    required this.gallerySaved,
  });

  final String savedPath;
  final int fileSizeBytes;
  final bool gallerySaved;
}
