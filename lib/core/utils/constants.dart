/// Available thread count options for multi-part downloads.
/// Each value splits the file into N simultaneous range requests.
/// Higher values improve speed on fast connections but increase server load.
const List<int> kAvailableThreadOptions = [1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 16];

String kAppVersion = '3.0.0+1';

void setAppVersion(String version) {
  if (version.isNotEmpty) {
    kAppVersion = version;
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
const String kDefaultApiKey = 'KxPgwFT0VvqoJUgVfcWuvE3-QSrc7qM-1YDS1dzNJv0';
const String kDefaultAdminToken = 'YSgQyzl_Ici5EMzdacBN-0kH3ja63JApwdq1M1QGSwc';

const List<String> kFallbackBackendBaseUrls = [
  'https://xdm-backend-10763667121.europe-west1.run.app',
  'https://xdm-backend-fallback.europe-west1.run.app',
];

