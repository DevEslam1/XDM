import 'package:dio/dio.dart';
import 'package:dmx/core/utils/constants.dart';
import 'package:flutter/foundation.dart';

void main() async {
  final dio = Dio();
  const targetVideo =
      'https://m.youtube.com/watch?v=04qaw2nx5qY&list=RD04qaw2nx5qY&start_radio=1&pp=oAcB';
  final url =
      '$kDefaultBackendBaseUrl/api/streams?url=${Uri.encodeComponent(targetVideo)}';
  debugPrint('Requesting: $url');
  try {
    final response = await dio.get(url);
    debugPrint('Status: ${response.statusCode}');
    debugPrint('Body: ${response.data}');
  } on DioException catch (e) {
    debugPrint('Error Status: ${e.response?.statusCode}');
    debugPrint('Error Body: ${e.response?.data}');
    debugPrint('Error Message: ${e.message}');
  } catch (e) {
    debugPrint('Generic Exception: $e');
  }
}
