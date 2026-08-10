import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../models/post_result.dart';
import '../models/profile_result.dart';
import '../models/reel_result.dart';
import 'download_service.dart';
import 'instagram_direct_service.dart';

final instagramApiServiceProvider = Provider<InstagramApiService>((ref) {
  return InstagramApiService(
    ref.watch(dioProvider),
    ref.watch(instagramDirectServiceProvider),
  );
});

class InstagramApiService {
  InstagramApiService(this._dio, this._direct);

  final Dio _dio;
  final InstagramDirectService _direct;

  Future<ReelResult> fetchReel(String url) async {
    try {
      final result = await _direct.fetchReel(url);
      _log('Reel extracted on-device');
      return result;
    } catch (e) {
      _log('On-device reel failed, using API fallback: $e');
      return _fetchReelFromApi(url);
    }
  }

  Future<PostResult> fetchPost(String url) async {
    try {
      final result = await _direct.fetchPost(url);
      _log('Post extracted on-device');
      return result;
    } catch (e) {
      _log('On-device post failed, using API fallback: $e');
      return _fetchPostFromApi(url);
    }
  }

  Future<List<int>> downloadCarouselZip(String url) async {
    try {
      final response = await _dio.post<List<int>>(
        '/api/instagram/carousel/zip',
        data: {'url': url},
        options: Options(responseType: ResponseType.bytes),
      );
      return response.data ?? [];
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<ProfileResult> fetchProfilePicture(String username) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/api/instagram/dp/$username',
      );
      return ProfileResult.fromJson(response.data!);
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<ProfilePictureDownloadResult> downloadProfilePicture(
    String username, {
    bool? upscale,
    void Function(FileDownloadProgress progress)? onProgress,
  }) async {
    try {
      final queryParams = <String, dynamic>{};
      if (upscale != null) {
        queryParams['upscale'] = upscale ? 1 : 0;
      }

      final response = await _dio.get<List<int>>(
        '/api/instagram/dp/$username/download',
        queryParameters: queryParams.isEmpty ? null : queryParams,
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: (received, total) {
          onProgress?.call(
            FileDownloadProgress(received: received, total: total),
          );
        },
      );

      final wasUpscaled =
          response.headers.value('x-dp-upscaled')?.toLowerCase() == 'true';

      return ProfilePictureDownloadResult(
        bytes: response.data ?? [],
        wasUpscaled: wasUpscaled,
      );
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<ReelResult> _fetchReelFromApi(String url) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/instagram/reel',
        data: {'url': url},
      );
      return ReelResult.fromJson(response.data!, url);
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  Future<PostResult> _fetchPostFromApi(String url) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/api/instagram/post',
        data: {'url': url},
      );
      return PostResult.fromJson(response.data!);
    } on DioException catch (e) {
      throw ApiException.fromDioException(e);
    }
  }

  void _log(String message) {
    if (kDebugMode) {
      debugPrint('[InstagramApi] $message');
    }
  }
}
