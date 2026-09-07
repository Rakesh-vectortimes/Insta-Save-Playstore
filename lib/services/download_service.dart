import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/api_client.dart';
import '../core/constants.dart';
import '../models/download_item.dart';
import 'instagram_cdn_utils.dart';

enum MediaSaveType { image, video, audio, zip, other }

class FileDownloadProgress {
  const FileDownloadProgress({required this.received, required this.total});

  final int received;
  final int total;

  double get fraction => total > 0 ? received / total : 0;
}

class DownloadService {
  DownloadService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  Future<bool> requestPermission(MediaSaveType type) async {
    if (kIsWeb) return true;

    if (Platform.isAndroid) {
      if (type == MediaSaveType.audio || type == MediaSaveType.zip) {
        return true;
      }
      Permission permission;
      if (type == MediaSaveType.video) {
        permission = Permission.videos;
      } else {
        permission = Permission.photos;
      }
      var status = await permission.status;
      if (!status.isGranted) {
        status = await permission.request();
      }
      if (status.isGranted) return true;

      final storage = await Permission.storage.request();
      return storage.isGranted;
    }

    if (Platform.isIOS) {
      if (type == MediaSaveType.audio || type == MediaSaveType.zip) {
        return true;
      }
      final status = await Permission.photos.request();
      return status.isGranted || status.isLimited;
    }

    return true;
  }

  Future<DownloadResult> downloadAndSave({
    required String url,
    required String fileName,
    required MediaSaveType saveType,
    Map<String, String>? extraHeaders,
    void Function(FileDownloadProgress progress)? onProgress,
  }) async {
    final hasPermission = await requestPermission(saveType);
    if (!hasPermission) {
      throw Exception('Storage permission is required to save files.');
    }

    final resolvedUrl = resolveApiUrl(url);
    final appDir = await _getAppDownloadsDirectory();
    final destPath = '${appDir.path}/$fileName';

    final headers = <String, dynamic>{
      ...InstagramCdnUtils.downloadHeaders,
      if (extraHeaders != null) ...extraHeaders,
    };
    if (InstagramCdnUtils.isInstagramCdn(resolvedUrl)) {
      headers['Referer'] ??= 'https://www.instagram.com/';
      headers['Origin'] ??= 'https://www.instagram.com';
    }

    try {
      await _dio.download(
        resolvedUrl,
        destPath,
        options: Options(
          headers: headers,
          followRedirects: true,
          validateStatus: (s) => s != null && s >= 200 && s < 400,
        ),
        onReceiveProgress: (received, total) {
          onProgress?.call(
            FileDownloadProgress(received: received, total: total),
          );
        },
      );
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 403 || code == 401) {
        throw Exception(
          'Instagram blocked the file (login session required). '
          'Open Instagram in the app, stay logged in, then try again.',
        );
      }
      throw Exception(
        'Download failed${code != null ? ' ($code)' : ''}. Please try again.',
      );
    }

    final file = File(destPath);
    final fileSize = await file.length();
    if (fileSize < 1024) {
      try {
        await file.delete();
      } catch (_) {}
      throw Exception('Download failed — file was empty or blocked.');
    }

    final probe = await file.openRead(0, 64).first;
    if (InstagramCdnUtils.looksLikeHtml(probe)) {
      try {
        await file.delete();
      } catch (_) {}
      throw Exception(
        'Download failed — Instagram blocked the media URL. Try again.',
      );
    }
    if (saveType == MediaSaveType.video &&
        !InstagramCdnUtils.looksLikeMp4(probe)) {
      try {
        await file.delete();
      } catch (_) {}
      throw Exception(
        'Downloaded file is not a playable video. Try Get Video again.',
      );
    }

    var gallerySaved = false;

    switch (saveType) {
      case MediaSaveType.image:
        await Gal.putImage(destPath, album: AppConstants.appName);
        gallerySaved = true;
      case MediaSaveType.video:
        await Gal.putVideo(destPath, album: AppConstants.appName);
        gallerySaved = true;
      case MediaSaveType.audio:
      case MediaSaveType.zip:
      case MediaSaveType.other:
        if (saveType == MediaSaveType.zip || saveType == MediaSaveType.audio) {
          final publicDir = await _getPublicDownloadsDirectory();
          final publicPath = '${publicDir.path}/$fileName';
          await File(destPath).copy(publicPath);
        }
    }

    return DownloadResult(
      savedPath: destPath,
      fileSizeBytes: fileSize,
      gallerySaved: gallerySaved,
    );
  }

  Future<DownloadResult> saveBytes({
    required List<int> bytes,
    required String fileName,
    required MediaSaveType saveType,
  }) async {
    final hasPermission = await requestPermission(saveType);
    if (!hasPermission) {
      throw Exception('Storage permission is required to save files.');
    }

    final appDir = await _getAppDownloadsDirectory();
    final destPath = '${appDir.path}/$fileName';
    await File(destPath).writeAsBytes(bytes);

    var gallerySaved = false;
    switch (saveType) {
      case MediaSaveType.image:
        await Gal.putImage(destPath, album: AppConstants.appName);
        gallerySaved = true;
      case MediaSaveType.video:
        await Gal.putVideo(destPath, album: AppConstants.appName);
        gallerySaved = true;
      case MediaSaveType.audio:
      case MediaSaveType.zip:
        final publicDir = await _getPublicDownloadsDirectory();
        await File(destPath).copy('${publicDir.path}/$fileName');
      case MediaSaveType.other:
        break;
    }

    return DownloadResult(
      savedPath: destPath,
      fileSizeBytes: bytes.length,
      gallerySaved: gallerySaved,
    );
  }

  Future<Directory> _getAppDownloadsDirectory() async {
    final dir = await getApplicationDocumentsDirectory();
    final downloads = Directory('${dir.path}/instasave_downloads');
    if (!await downloads.exists()) {
      await downloads.create(recursive: true);
    }
    return downloads;
  }

  Future<Directory> _getPublicDownloadsDirectory() async {
    if (Platform.isAndroid) {
      final dir = Directory('/storage/emulated/0/Download');
      if (await dir.exists()) return dir;
    }
    return _getAppDownloadsDirectory();
  }

  MediaSaveType typeFromExtension(String ext) {
    final lower = ext.toLowerCase();
    if (lower == 'mp4' || lower == 'mov' || lower == 'webm') {
      return MediaSaveType.video;
    }
    if (lower == 'mp3' || lower == 'm4a' || lower == 'aac') {
      return MediaSaveType.audio;
    }
    if (lower == 'zip') return MediaSaveType.zip;
    return MediaSaveType.image;
  }

  DownloadMediaType mediaTypeFromSaveType(MediaSaveType type) {
    switch (type) {
      case MediaSaveType.video:
        return DownloadMediaType.video;
      case MediaSaveType.audio:
        return DownloadMediaType.music;
      case MediaSaveType.zip:
        return DownloadMediaType.zip;
      case MediaSaveType.image:
      case MediaSaveType.other:
        return DownloadMediaType.photo;
    }
  }

  String buildFileName({
    required String prefix,
    required String ext,
    int? index,
  }) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final suffix = index != null ? '_$index' : '';
    return '$prefix${suffix}_$timestamp.$ext';
  }

  String qualityLabel(int quality) {
    if (quality >= 1080) return 'FHD';
    if (quality >= 720) return 'HD';
    return '${quality}p';
  }
}
