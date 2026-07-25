import 'package:dio/dio.dart';
import 'package:dmx/core/utils/constants.dart';

void main() async {
  final dio = Dio();
  final targetVideo = 'https://m.youtube.com/watch?v=04qaw2nx5qY&list=RD04qaw2nx5qY&start_radio=1&pp=oAcB';
  final url = '$kDefaultBackendBaseUrl/api/streams?url=${Uri.encodeComponent(targetVideo)}';
  print('Requesting: $url');
  try {
    final response = await dio.get(url);
    print('Status: ${response.statusCode}');
    print('Body: ${response.data}');
  } on DioException catch (e) {
    print('Error Status: ${e.response?.statusCode}');
    print('Error Body: ${e.response?.data}');
    print('Error Message: ${e.message}');
  } catch (e) {
    print('Generic Exception: $e');
  }
}
