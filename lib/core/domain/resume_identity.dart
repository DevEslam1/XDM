import 'package:flutter/foundation.dart';

/// Represents the immutable identity of a remote resource for validating
/// that byte-range resume attempts match the remote file.
@immutable
class ResumeIdentity {
  final String normalizedUrl;
  final String? etag;
  final String? lastModified;
  final int? contentLength;
  final bool supportsRanges;
  final String? expectedSha256;
  final String? mirrorGroupId;

  const ResumeIdentity({
    required this.normalizedUrl,
    this.etag,
    this.lastModified,
    this.contentLength,
    this.supportsRanges = false,
    this.expectedSha256,
    this.mirrorGroupId,
  });

  /// Normalizes a URL string by trimming whitespace and removing fragment identifiers.
  static String normalizeUrl(String url) {
    final trimmed = url.trim();
    final hashIndex = trimmed.indexOf('#');
    if (hashIndex != -1) {
      return trimmed.substring(0, hashIndex);
    }
    return trimmed;
  }

  /// Factory constructor to create a [ResumeIdentity] from HTTP headers and request URL.
  factory ResumeIdentity.fromHeaders({
    required String url,
    required Map<String, dynamic> headers,
    int? contentLength,
    String? expectedSha256,
    String? mirrorGroupId,
  }) {
    String? etag;
    String? lastModified;
    bool supportsRanges = false;
    int? length = contentLength;

    for (final entry in headers.entries) {
      final key = entry.key.toLowerCase();
      final val = entry.value;
      final strVal = val is List ? val.firstOrNull?.toString() : val?.toString();
      if (strVal == null || strVal.isEmpty) continue;

      if (key == 'etag') {
        etag = strVal.trim();
      } else if (key == 'last-modified') {
        lastModified = strVal.trim();
      } else if (key == 'accept-ranges') {
        supportsRanges = strVal.toLowerCase().contains('bytes');
      } else if (key == 'content-length' && length == null) {
        length = int.tryParse(strVal.trim());
      }
    }

    return ResumeIdentity(
      normalizedUrl: normalizeUrl(url),
      etag: etag,
      lastModified: lastModified,
      contentLength: length,
      supportsRanges: supportsRanges,
      expectedSha256: expectedSha256,
      mirrorGroupId: mirrorGroupId,
    );
  }

  /// Serializes [ResumeIdentity] to a JSON-compatible map for persistence.
  Map<String, dynamic> toJson() => {
        'normalizedUrl': normalizedUrl,
        'etag': etag,
        'lastModified': lastModified,
        'contentLength': contentLength,
        'supportsRanges': supportsRanges,
        if (expectedSha256 != null) 'expectedSha256': expectedSha256,
        if (mirrorGroupId != null) 'mirrorGroupId': mirrorGroupId,
      };

  /// Deserializes [ResumeIdentity] from a JSON map.
  factory ResumeIdentity.fromJson(Map<String, dynamic> json) {
    return ResumeIdentity(
      normalizedUrl: json['normalizedUrl'] as String? ?? '',
      etag: json['etag'] as String?,
      lastModified: json['lastModified'] as String?,
      contentLength: (json['contentLength'] as num?)?.toInt(),
      supportsRanges: json['supportsRanges'] as bool? ?? false,
      expectedSha256: json['expectedSha256'] as String?,
      mirrorGroupId: json['mirrorGroupId'] as String?,
    );
  }

  /// Validates whether a [candidate] identity matches this initial [ResumeIdentity].
  /// Returns a [ResumeValidationResult] detailing whether resume is safe.
  ResumeValidationResult validateAgainst(ResumeIdentity candidate) {
    // 1. Content length check: if both know content length and they differ
    if (contentLength != null &&
        contentLength! > 0 &&
        candidate.contentLength != null &&
        candidate.contentLength! > 0 &&
        contentLength != candidate.contentLength) {
      return ResumeValidationResult.mismatch(
        'Remote content length changed: expected $contentLength, got ${candidate.contentLength}',
      );
    }

    // 2. Strong ETag comparison
    if (etag != null &&
        candidate.etag != null &&
        !_etagsMatch(etag!, candidate.etag!)) {
      return ResumeValidationResult.mismatch(
        'Remote ETag changed: expected $etag, got ${candidate.etag}',
      );
    }

    // 3. Last-Modified comparison if ETags are absent
    if (etag == null &&
        candidate.etag == null &&
        lastModified != null &&
        candidate.lastModified != null &&
        lastModified != candidate.lastModified) {
      return ResumeValidationResult.mismatch(
        'Remote Last-Modified changed: expected $lastModified, got ${candidate.lastModified}',
      );
    }

    // 4. Mirror equivalence check
    if (mirrorGroupId != null &&
        candidate.mirrorGroupId != null &&
        mirrorGroupId != candidate.mirrorGroupId) {
      return ResumeValidationResult.mismatch(
        'Mirror group mismatch: expected $mirrorGroupId, got ${candidate.mirrorGroupId}',
      );
    }

    return const ResumeValidationResult.valid();
  }

  static bool _etagsMatch(String a, String b) {
    final cleanA = a.startsWith('W/') ? a.substring(2) : a;
    final cleanB = b.startsWith('W/') ? b.substring(2) : b;
    return cleanA.trim() == cleanB.trim();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResumeIdentity &&
          runtimeType == other.runtimeType &&
          normalizedUrl == other.normalizedUrl &&
          etag == other.etag &&
          lastModified == other.lastModified &&
          contentLength == other.contentLength &&
          supportsRanges == other.supportsRanges &&
          expectedSha256 == other.expectedSha256 &&
          mirrorGroupId == other.mirrorGroupId;

  @override
  int get hashCode => Object.hash(
        normalizedUrl,
        etag,
        lastModified,
        contentLength,
        supportsRanges,
        expectedSha256,
        mirrorGroupId,
      );
}

/// Result of validating a resume candidate against an established [ResumeIdentity].
class ResumeValidationResult {
  final bool isValid;
  final String? mismatchReason;

  const ResumeValidationResult.valid()
      : isValid = true,
        mismatchReason = null;

  const ResumeValidationResult.mismatch(this.mismatchReason)
      : isValid = false;

  @override
  String toString() =>
      isValid ? 'ResumeValidationResult.valid()' : 'ResumeValidationResult.mismatch($mismatchReason)';
}
