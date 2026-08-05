// ignore_for_file: avoid_print
import 'package:dio/dio.dart';

Future<void> main() async {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'https://xdm-backend-10763667121.europe-west1.run.app',
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 45),
    ),
  );

  const apiKey = 'KxPgwFT0VvqoJUgVfcWuvE3-QSrc7qM-1YDS1dzNJv0';

  final headers = {
    'Accept': 'application/json',
    'Authorization': 'Bearer $apiKey',
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  };

  print('=== Testing Backend Health ===');
  try {
    final healthResponse =
        await dio.get('/health', options: Options(headers: headers));
    print('Health status code: ${healthResponse.statusCode}');
    print('Health response: ${healthResponse.data}');
  } catch (e) {
    print('Health check failed: $e');
  }

  print('\n=== Testing API Search ("flutter") ===');
  try {
    final searchResponse = await dio.get(
      '/api/search',
      queryParameters: {'q': 'flutter'},
      options: Options(headers: headers),
    );
    print('Search status code: ${searchResponse.statusCode}');
    final data = searchResponse.data;
    if (data is Map) {
      final results = data['results'] as List?;
      print('Found ${results?.length ?? 0} results.');
      if (results != null && results.isNotEmpty) {
        final first = results.first as Map<String, dynamic>;
        print('First result title: ${first['title']}');
        print('First result url: ${first['url']}');
      }
    } else {
      print('Unexpected response format: $data');
    }
  } catch (e) {
    print('Search failed: $e');
  }

  print('\n=== Testing Streams Endpoint (with a sample video) ===');
  try {
    // A stable public video URL
    const videoUrl = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';
    final streamsResponse = await dio.get(
      '/api/streams',
      queryParameters: {'url': videoUrl},
      options: Options(headers: headers),
    );
    print('Streams status code: ${streamsResponse.statusCode}');
    final data = streamsResponse.data;
    if (data is Map) {
      print('Title: ${data['title']}');
      print('Keys in response: ${data.keys.toList()}');
      final streams = data['streams'] as List?;
      print('Available formats/streams count: ${streams?.length ?? 0}');
      if (streams != null && streams.isNotEmpty) {
        print('First stream info: ${streams.first}');
      }
    } else {
      print('Unexpected response format: $data');
    }
  } catch (e) {
    print('Streams endpoint failed: $e');
  }
}
