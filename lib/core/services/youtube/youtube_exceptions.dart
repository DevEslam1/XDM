/// Typed exception hierarchy for YouTube/InnerTube errors.
///
/// These map directly to YouTube's `playabilityStatus` responses,
/// enabling precise error handling and localized user messages.
library;

/// Base exception for all YouTube-related failures.
class YouTubeException implements Exception {
  final String message;
  final String? videoId;

  const YouTubeException(this.message, {this.videoId});

  @override
  String toString() =>
      'YouTubeException: $message'
      '${videoId != null ? ' (video: $videoId)' : ''}';
}

/// Video requires age verification / sign-in to access.
class AgeRestrictedException extends YouTubeException {
  const AgeRestrictedException(super.message, {super.videoId});

  @override
  String toString() => 'AgeRestrictedException: $message';
}

/// Video is marked as private by the uploader.
class PrivateVideoException extends YouTubeException {
  const PrivateVideoException(super.message, {super.videoId});

  @override
  String toString() => 'PrivateVideoException: $message';
}

/// Video is not available in the user's country/region.
class GeoBlockedException extends YouTubeException {
  const GeoBlockedException(super.message, {super.videoId});

  @override
  String toString() => 'GeoBlockedException: $message';
}

/// Video requires authentication (sign-in) to play.
class LoginRequiredException extends YouTubeException {
  const LoginRequiredException(super.message, {super.videoId});

  @override
  String toString() => 'LoginRequiredException: $message';
}

/// No playable streams were found for the video.
class NoStreamsException extends YouTubeException {
  const NoStreamsException(super.message, {super.videoId});

  @override
  String toString() => 'NoStreamsException: $message';
}

/// Stream is throttled due to n-param descrambling requirement.
class ThrottledException extends YouTubeException {
  const ThrottledException(super.message, {super.videoId});

  @override
  String toString() => 'ThrottledException: $message';
}

/// Video is a live stream that cannot be downloaded directly.
class LiveStreamException extends YouTubeException {
  const LiveStreamException(super.message, {super.videoId});

  @override
  String toString() => 'LiveStreamException: $message';
}
