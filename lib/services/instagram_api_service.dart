import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../models/post_result.dart';
import '../models/profile_result.dart';
import '../models/reel_result.dart';

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
}
