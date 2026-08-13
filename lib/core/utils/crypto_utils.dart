import 'dart:convert';
import 'package:crypto/crypto.dart';

bool timingSafeEqual(String a, String b) {
  final hashA = sha256.convert(utf8.encode(a)).bytes;
  final hashB = sha256.convert(utf8.encode(b)).bytes;
  var result = 0;
  for (var i = 0; i < hashA.length; i++) {
    result |= hashA[i] ^ hashB[i];
  }
  return result == 0;
}

/// Stretches [secret] with [salt] using 10,000 iterations of SHA-256 to mitigate brute force attacks.
String hashSecret(String secret, {String salt = ''}) {
  List<int> currentBytes = utf8.encode('$salt:$secret');
  for (var i = 0; i < 10000; i++) {
    currentBytes = sha256.convert(currentBytes).bytes;
  }
  return base64Encode(currentBytes);
}

/// Legacy un-stretched SHA-256 helper for backward compatibility.
String legacyHashSecret(String secret, {String salt = ''}) {
  final bytes = utf8.encode('$salt:$secret');
  return sha256.convert(bytes).toString();
}
