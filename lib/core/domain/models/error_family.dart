/// High-level family of an error, used to decide user messaging, retry policy
/// and severity.
enum ErrorFamily {
  network,
  server,
  auth,
  disk,
  integrity,
  cancelled,
  timeout,
  parse,
  unknown,
}
