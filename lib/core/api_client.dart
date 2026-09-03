import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
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
    debugPrint(
      '[ApiClient] Retrying attempt ${attempt + 1} after ${delay.inSeconds}s...',
    );
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
    if (status != 503 && status != 429 && status != 502) return false;

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

  factory ApiException.fromDioException(
    DioException error, {
    String? feature,
  }) {
    final response = error.response;
    final status = response?.statusCode;
    final data = response?.data;
    final map = data is Map ? Map<String, dynamic>.from(data) : null;

    final serverMessage = _readServerMessage(map);
    final reasonCode = map?['reasonCode'] as String?;
    final scopeLimited = map?['scopeLimited'] as bool? ?? false;
    final retryableFlag = map?['retryable'] as bool?;
    final retryAfter = map?['retryAfterSeconds'];

    if (serverMessage != null &&
        serverMessage.isNotEmpty &&
        !_isGenericServerMessage(serverMessage)) {
      return ApiException(
        message: serverMessage,
        scopeLimited: scopeLimited,
        retryable: retryableFlag ?? _defaultRetryable(status),
        reasonCode: reasonCode,
        statusCode: status,
        retryAfterSeconds: _asInt(retryAfter),
      );
    }

    final mapped = _mapStatusMessage(
      status: status,
      reasonCode: reasonCode,
      feature: feature,
      scopeLimited: scopeLimited,
    );
    if (mapped != null) return mapped;

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
      message: feature == 'dp'
          ? 'Unable to retrieve the profile picture. Please check the username and try again.'
          : 'Something went wrong. Please try again.',
      retryable: true,
      statusCode: status,
      reasonCode: reasonCode,
    );
  }

  static String? _readServerMessage(Map<String, dynamic>? map) {
    if (map == null) return null;
    for (final key in ['error', 'message', 'detail']) {
      final value = map[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  static bool _isGenericServerMessage(String message) {
    final lower = message.toLowerCase();
    return lower.contains('application failed to respond') ||
        lower.contains('internal server error') ||
        lower == 'error';
  }

  static bool _defaultRetryable(int? status) {
    return status == null ||
        status == 408 ||
        status == 429 ||
        status == 502 ||
        status == 503 ||
        status == 504;
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }

  static ApiException? _mapStatusMessage({
    required int? status,
    required String? reasonCode,
    required String? feature,
    required bool scopeLimited,
  }) {
    final code = (reasonCode ?? '').toLowerCase();

    if (code.contains('private') || scopeLimited) {
      return ApiException(
        message: feature == 'dp'
            ? 'This account is private and the profile picture cannot be accessed.'
            : 'This content is private or restricted and cannot be downloaded.',
        scopeLimited: true,
        retryable: false,
        reasonCode: reasonCode,
        statusCode: status,
      );
    }

    if (code.contains('not_found') ||
        code.contains('notfound') ||
        status == 404) {
      return ApiException(
        message: feature == 'dp'
            ? 'Profile could not be found. Check the username and try again.'
            : 'Content could not be found. Check the link and try again.',
        retryable: false,
        reasonCode: reasonCode,
        statusCode: status,
      );
    }

    if (code.contains('rate') || status == 429) {
      return ApiException(
        message: 'Too many requests. Please wait a moment and try again.',
        retryable: true,
        reasonCode: reasonCode,
        statusCode: status,
        retryAfterSeconds: 5,
      );
    }

    if (code.contains('timeout') ||
        code == 'dp_timeout' ||
        status == 502 ||
        status == 503 ||
        status == 504) {
      return ApiException(
        message: feature == 'dp'
            ? 'Unable to retrieve the profile picture. Please check the username and try again.'
            : 'Service is temporarily unavailable. Please try again in a moment.',
        retryable: true,
        reasonCode: reasonCode,
        statusCode: status,
        retryAfterSeconds: 5,
      );
    }

    return null;
  }
}

String resolveApiUrl(String url) {
  if (url.startsWith('http://') || url.startsWith('https://')) {
    return url;
  }
  final path = url.startsWith('/') ? url : '/$url';
  return '${AppConstants.apiBaseUrl}$path';
}
