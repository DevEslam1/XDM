class DownloadConfig {
  final int maxDownloads;
  final int speedLimitBytes;
  final bool wifiOnly;
  final bool autoStart;
  final int defaultThreadCount;
  final bool adaptiveThreads;

  const DownloadConfig({
    this.maxDownloads = 3,
    this.speedLimitBytes = 0,
    this.wifiOnly = false,
    this.autoStart = true,
    this.defaultThreadCount = 4,
    this.adaptiveThreads = true,
  });
}
