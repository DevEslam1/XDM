import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Constant-time string comparison to prevent timing side-channel attacks on tokens/signatures.
bool timingSafeEqual(String a, String b) {
  final hashA = sha256.convert(utf8.encode(a)).bytes;
  final hashB = sha256.convert(utf8.encode(b)).bytes;
  var result = 0;
  for (var i = 0; i < hashA.length; i++) {
    result |= hashA[i] ^ hashB[i];
  }
  return result == 0;
}

/// Hashes a plaintext secret using SHA-256 with optional salt.
String hashSecret(String secret, {String salt = ''}) {
  final bytes = utf8.encode('$salt:$secret');
  final digest = sha256.convert(bytes);
  return digest.toString();
}
