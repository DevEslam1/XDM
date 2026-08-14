import 'dart:convert';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/key_derivators/pbkdf2.dart';
import 'package:pointycastle/macs/hmac.dart';

bool timingSafeEqual(String a, String b) {
  final hashA = sha256.convert(utf8.encode(a)).bytes;
  final hashB = sha256.convert(utf8.encode(b)).bytes;
  var result = 0;
  for (var i = 0; i < hashA.length; i++) {
    result |= hashA[i] ^ hashB[i];
  }
  return result == 0;
}

/// PBKDF2 derivation with SHA-256 HMAC (SEC-04).
String pbkdf2Hash(
  String secret,
  String salt, {
  int iterations = 100000,
  int keyLength = 32,
}) {
  final generator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(utf8.encode(salt), iterations, keyLength));
  return hex.encode(generator.process(utf8.encode(secret)));
}

/// Stretches [secret] with [salt] using 10,000 iterations of SHA-256 (legacy intermediate).
String hashSecret(String secret, {String salt = ''}) {
  return 'pbkdf2:$salt:${pbkdf2Hash(secret, salt)}';
}

/// Legacy stretched SHA-256 helper for backward compatibility.
String legacyStretchedHash(String secret, {String salt = ''}) {
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
