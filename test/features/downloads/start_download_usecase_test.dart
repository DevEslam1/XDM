// These tests previously validated StartDownloadUseCase's direct integration with
// DownloadListProvider + DownloadQueueProvider. That architecture was an orphaned
// "Clean Architecture" scaffolding layer that was never wired to real UI callsites.
//
// StartDownloadUseCase is now a @Deprecated stub. The integration tests for the
// real start-download flow live in the DownloadProvider integration tests which
// exercise DownloadProvider.addDownload() directly.
//
// See: test/integration/download_provider_test.dart
//      lib/features/downloads/usecases/start_download_usecase.dart (docstring)
