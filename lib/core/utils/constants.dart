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

const String kDeveloperName = '';
const String kDeveloperTitle = '';
const String kDeveloperEmail = '';
const String kDeveloperGithub = '';
const String kDeveloperLinkedin = '';
const String kDeveloperPhone = '';

const String kDefaultBackendBaseUrl = 'https://xdm-backend.onrender.com';
