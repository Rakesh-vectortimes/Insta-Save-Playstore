import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'constants.dart';

final dioProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      baseUrl: AppConstants.apiBaseUrl,
      connectTimeout: const Duration(seconds: 30),
      // Covers backend wait-queue (up to ~30s) + Instagram extract.
      receiveTimeout: const Duration(seconds: 120),
      headers: {'Content-Type': 'application/json'},
    ),
  );
  dio.interceptors.add(RetryInterceptor(dio));
  return dio;
});

/// Auto-retries capacity / transient failures so users rarely see a 503.
class RetryInterceptor extends Interceptor {
  RetryInterceptor(
    this._dio, {
    this.maxRetries = 2,
  });

  final Dio _dio;
  final int maxRetries;

  static const _attemptKey = 'retryAttempt';

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final attempt = (err.requestOptions.extra[_attemptKey] as int?) ?? 0;

    if (!_shouldRetry(err) || attempt >= maxRetries) {
      return handler.next(err);
    }

    final delay = Duration(seconds: _retryAfterSeconds(err, attempt));
    await Future<void>.delayed(delay);

    final options = err.requestOptions;
    options.extra[_attemptKey] = attempt + 1;

    try {
      final response = await _dio.fetch<dynamic>(options);
      return handler.resolve(response);
    } on DioException catch (e) {
      return handler.next(e);
    }
  }

  bool _shouldRetry(DioException err) {
    if (err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.connectionError) {
      return true;
    }

    final status = err.response?.statusCode;
    if (status != 503 && status != 429) return false;

    final data = err.response?.data;
    if (data is Map && data['retryable'] == false) return false;
    return true;
  }

  int _retryAfterSeconds(DioException err, int attempt) {
    final data = err.response?.data;
    if (data is Map) {
      final raw = data['retryAfterSeconds'];
      if (raw is int && raw > 0) return raw;
      if (raw is num && raw > 0) return raw.toInt();
    }
    // 2s, then 4s
    return 2 * (attempt + 1);
  }
}

class ApiException implements Exception {
  ApiException({
    required this.message,
    this.scopeLimited = false,
    this.retryable = false,
    this.reasonCode,
    this.statusCode,
    this.retryAfterSeconds,
  });

  final String message;
  final bool scopeLimited;
  final bool retryable;
  final String? reasonCode;
  final int? statusCode;
  final int? retryAfterSeconds;

  @override
  String toString() => message;

  factory ApiException.fromDioException(DioException error) {
    final response = error.response;
    final data = response?.data;

    if (data is Map<String, dynamic>) {
      final retryAfter = data['retryAfterSeconds'];
      return ApiException(
        message: data['error'] as String? ??
            'Something went wrong. Please try again.',
        scopeLimited: data['scopeLimited'] as bool? ?? false,
        retryable: data['retryable'] as bool? ?? false,
        reasonCode: data['reasonCode'] as String?,
        statusCode: response?.statusCode,
        retryAfterSeconds: retryAfter is int
            ? retryAfter
            : retryAfter is num
                ? retryAfter.toInt()
                : null,
      );
    }

    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.connectionError) {
      return ApiException(
        message: 'Connection failed. Check your internet and try again.',
        retryable: true,
        retryAfterSeconds: 3,
      );
    }

    return ApiException(
      message: 'Something went wrong. Please try again.',
      retryable: true,
      statusCode: response?.statusCode,
    );
  }
}

String resolveApiUrl(String url) {
  if (url.startsWith('http://') || url.startsWith('https://')) {
    return url;
  }
  final path = url.startsWith('/') ? url : '/$url';
  return '${AppConstants.apiBaseUrl}$path';
}
