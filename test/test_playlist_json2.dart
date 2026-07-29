// ignore_for_file: avoid_print, avoid_dynamic_calls
import 'dart:convert';
import 'package:dio/dio.dart';

void main() async {
  final dio = Dio();
  final response = await dio.get(
    'https://www.youtube.com/playlist?list=PLFgofPyD3Bck5vCNEsD9SxpIa74x3a1h2',
  );
  final html = response.data as String;
  final start = html.indexOf('var ytInitialData = ');
  if (start != -1) {
    final end = html.indexOf(';</script>', start);
    final jsonStr = html.substring(start + 20, end);
    final data = jsonDecode(jsonStr);
    print(data['contents']?.keys);
  }
}
