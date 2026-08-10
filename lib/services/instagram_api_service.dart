import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../models/post_result.dart';
import '../models/profile_result.dart';
import '../models/reel_result.dart';
import 'download_service.dart';

final instagramApiServiceProvider = Provider<InstagramApiService>((ref) {
  return InstagramApiService(ref.watch(dioProvider));
});

class InstagramApiService {
  InstagramApiService(this._dio);

  final Dio _dio;

  Future<ReelResult> fetchReel(String url) async {
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

  Future<PostResult> fetchPost(String url) async {
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
}
