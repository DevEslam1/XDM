class DownloadMetrics {
  final String taskId;
  final String url;
  final DateTime startedAt;
  DateTime? completedAt;

  int timeToFirstByteMs = 0;
  bool usedHttp2 = false;
  int requestedThreads = 0;
  int effectiveThreads = 0;
  int totalBytesDownloaded = 0;
  int peakSpeedBps = 0;
  int totalRetries = 0;
  bool resumed = false;
  int resumeBytesSaved = 0;
  String? checksumAlgorithm;
  bool checksumVerified = false;
  bool checksumPassed = false;
  int errorCount = 0;
  String? lastError;
  int mirrorSwitches = 0;

  DownloadMetrics({required this.taskId, required this.url})
      : startedAt = DateTime.now();

  void markCompleted() {
    completedAt = DateTime.now();
  }

  Duration get elapsed =>
      (completedAt ?? DateTime.now()).difference(startedAt);

  double get avgSpeedBps =>
      elapsed.inMilliseconds > 0
          ? totalBytesDownloaded / elapsed.inMilliseconds * 1000
          : 0;

  double get threadEfficiency {
    if (effectiveThreads <= 1 || peakSpeedBps <= 0) return 1.0;
    final theoretical = peakSpeedBps * effectiveThreads;
    return (avgSpeedBps / theoretical).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
        'taskId': taskId,
        'url': url,
        'startedAt': startedAt.toIso8601String(),
        'completedAt': completedAt?.toIso8601String(),
        'elapsedMs': elapsed.inMilliseconds,
        'ttfbMs': timeToFirstByteMs,
        'http2': usedHttp2,
        'requestedThreads': requestedThreads,
        'effectiveThreads': effectiveThreads,
        'bytesDownloaded': totalBytesDownloaded,
        'peakSpeedBps': peakSpeedBps,
        'avgSpeedBps': avgSpeedBps.round(),
        'threadEfficiency':
            double.parse(threadEfficiency.toStringAsFixed(3)),
        'totalRetries': totalRetries,
        'resumed': resumed,
        'resumeBytesSaved': resumeBytesSaved,
        'checksumAlgorithm': checksumAlgorithm,
        'checksumVerified': checksumVerified,
        'checksumPassed': checksumPassed,
        'errorCount': errorCount,
        'lastError': lastError,
        'mirrorSwitches': mirrorSwitches,
      };

  factory DownloadMetrics.fromJson(Map<String, dynamic> json) {
    final m = DownloadMetrics(
      taskId: json['taskId'] as String? ?? '',
      url: json['url'] as String? ?? '',
    );
    m.timeToFirstByteMs = json['ttfbMs'] as int? ?? 0;
    m.usedHttp2 = json['http2'] as bool? ?? false;
    m.requestedThreads = json['requestedThreads'] as int? ?? 0;
    m.effectiveThreads = json['effectiveThreads'] as int? ?? 0;
    m.totalBytesDownloaded = json['bytesDownloaded'] as int? ?? 0;
    m.peakSpeedBps = json['peakSpeedBps'] as int? ?? 0;
    m.totalRetries = json['totalRetries'] as int? ?? 0;
    m.resumed = json['resumed'] as bool? ?? false;
    m.resumeBytesSaved = json['resumeBytesSaved'] as int? ?? 0;
    m.checksumAlgorithm = json['checksumAlgorithm'] as String?;
    m.checksumVerified = json['checksumVerified'] as bool? ?? false;
    m.checksumPassed = json['checksumPassed'] as bool? ?? false;
    m.errorCount = json['errorCount'] as int? ?? 0;
    m.lastError = json['lastError'] as String?;
    m.mirrorSwitches = json['mirrorSwitches'] as int? ?? 0;
    if (json['completedAt'] != null) {
      m.completedAt = DateTime.parse(json['completedAt'] as String);
    }
    return m;
  }

  String toSummary() {
    final buf = StringBuffer();
    buf.writeln('Download: $url');
    buf.writeln('Duration: ${elapsed.inSeconds}s');
    buf.writeln('TTFB: ${timeToFirstByteMs}ms');
    buf.writeln('Speed: avg ${(avgSpeedBps / 1024 / 1024).toStringAsFixed(1)} MB/s, '
        'peak ${(peakSpeedBps / 1024 / 1024).toStringAsFixed(1)} MB/s');
    buf.writeln('Threads: $effectiveThreads/$requestedThreads '
        '(efficiency: ${(threadEfficiency * 100).toStringAsFixed(0)}%)');
    buf.writeln('HTTP/2: $usedHttp2');
    buf.writeln('Resumed: $resumed (saved ${(resumeBytesSaved / 1024 / 1024).toStringAsFixed(1)} MB)');
    buf.writeln('Retries: $totalRetries');
    if (checksumVerified) {
      buf.writeln('Checksum ($checksumAlgorithm): ${checksumPassed ? "PASS" : "FAIL"}');
    }
    if (errorCount > 0) {
      buf.writeln('Errors: $errorCount (last: $lastError)');
    }
    return buf.toString();
  }
}