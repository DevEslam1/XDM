/// Available thread count options for multi-part downloads.
/// Each value splits the file into N simultaneous range requests.
/// Higher values improve speed on fast connections but increase server load.
const List<int> kAvailableThreadOptions = [1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 16];

String _kAppVersion = '3.0.0+1';
String get kAppVersion => _kAppVersion;

void setAppVersion(String version) {
  if (version.isNotEmpty) {
    _kAppVersion = version;
  }
}

const String kDeveloperName = 'Eslam Mahmoud';
const String kDeveloperTitle = 'Mobile Development Engineer';
const String kDeveloperEmail = 'xdev.eslam@gmail.com';
const String kDeveloperGithub = 'github.com/DevEslam1';
const String kDeveloperLinkedin = 'linkedin.com/in/deveslam-mahmoud';
const String kDeveloperPhone = '+20 112 229 9831';

const String kDefaultBackendBaseUrl =
    'https://xdm-backend-10763667121.europe-west1.run.app';

const List<String> kFallbackBackendBaseUrls = [
  'https://xdm-backend-10763667121.europe-west1.run.app',
  'https://xdm-backend-fallback.europe-west1.run.app',
];
