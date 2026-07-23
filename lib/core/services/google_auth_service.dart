import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'youtube_service.dart';

/// Handles Google Sign-In and automatically authenticates YouTube.
///
/// After a successful Google Sign-In, the OAuth access token is passed
/// to YouTube's InnerTube API via `Authorization: Bearer <token>`.
/// This unlocks age-restricted content and higher quality streams.
///
/// Auth state is persisted so the user stays signed in across app restarts.
class GoogleAuthService {
  GoogleAuthService._();
  static final GoogleAuthService _instance = GoogleAuthService._();
  factory GoogleAuthService() => _instance;

  static const _prefSignedIn = 'google_auth_signed_in';
  static const _prefUserEmail = 'google_auth_user_email';
  static const _prefUserName = 'google_auth_user_name';
  static const _prefPhotoUrl = 'google_auth_photo_url';

  static final _secureStorage = const FlutterSecureStorage();

  /// YouTube OAuth scope — required for InnerTube authenticated requests.
  static const _youtubeScope = 'https://www.googleapis.com/auth/youtube';

  /// Optional Server Client ID (Web Application Client ID from Google Cloud Console).
  /// Override via --dart-define=GOOGLE_SERVER_CLIENT_ID=<your_id>
  static String? serverClientId =
      const String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID',
          defaultValue: '978586541696-qi3ggijiatj2baf3ib4eg25aedls9llv.apps.googleusercontent.com');

  /// Optional Client ID.
  /// Override via --dart-define=GOOGLE_CLIENT_ID=<your_id>
  static String? clientId =
      const String.fromEnvironment('GOOGLE_CLIENT_ID',
          defaultValue: '978586541696-qi3ggijiatj2baf3ib4eg25aedls9llv.apps.googleusercontent.com');

  GoogleSignIn? _signInInstance;
  GoogleSignIn get _googleSignIn {
    return _signInInstance ??= GoogleSignIn(
      clientId: clientId,
      serverClientId: serverClientId,
      scopes: [
        'email',
        'profile',
        _youtubeScope,
      ],
      forceCodeForRefreshToken: true,
    );
  }

  GoogleSignInAccount? _currentUser;
  String? _accessToken;
  DateTime? _tokenExpiry;
  bool _isInitialized = false;

  final _authStateController = StreamController<bool>.broadcast();

  // ──────────────────── Public API ────────────────────

  /// Stream that emits `true` when signed in, `false` when signed out.
  Stream<bool> get onAuthStateChanged => _authStateController.stream;

  /// Whether a Google account is currently signed in.
  bool get isSignedIn => _currentUser != null;

  /// The signed-in Google account, or null.
  GoogleSignInAccount? get currentUser => _currentUser;

  /// Display name of the signed-in user.
  String? get userName => _currentUser?.displayName;

  /// Email of the signed-in user.
  String? get userEmail => _currentUser?.email;

  /// Photo URL of the signed-in user.
  String? get userPhotoUrl => _currentUser?.photoUrl;

  /// Returns a valid OAuth access token, refreshing if expired.
  /// Returns null if not signed in or token refresh fails.
  Future<String?> getAccessToken() async {
    if (_currentUser == null) return null;

    // Return cached token if still valid (with 60s buffer)
    if (_accessToken != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(
          _tokenExpiry!.subtract(const Duration(seconds: 60)),
        )) {
      return _accessToken;
    }

    try {
      final auth = await _currentUser!.authentication;
      _accessToken = auth.accessToken;
      // Google tokens typically last 1 hour
      _tokenExpiry = DateTime.now().add(const Duration(minutes: 55));
      return _accessToken;
    } catch (e) {
      debugPrint('[GoogleAuth] Token refresh failed: $e');
      // Try silent re-auth
      try {
        final account = await _googleSignIn.signInSilently();
        if (account != null) {
          _currentUser = account;
          final auth = await account.authentication;
          _accessToken = auth.accessToken;
          _tokenExpiry = DateTime.now().add(const Duration(minutes: 55));
          return _accessToken;
        }
      } catch (_) {}
      return null;
    }
  }

  /// Initialize auth state on app startup.
  /// Attempts silent sign-in to restore previous session.
  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;

    _googleSignIn.onCurrentUserChanged.listen((account) {
      _currentUser = account;
      _authStateController.add(account != null);
      if (account != null) {
        _onSignedIn(account);
      } else {
        _onSignedOut();
      }
    });

    // Try silent sign-in to restore previous session
    try {
      final account = await _googleSignIn.signInSilently();
      if (account != null) {
        _currentUser = account;
        await _onSignedIn(account);
        debugPrint('[GoogleAuth] Restored session for ${account.email}');
      }
    } catch (e) {
      debugPrint('[GoogleAuth] Silent sign-in failed: $e');
    }
  }

  /// Opens the native Google Sign-In dialog.
  /// Returns true if sign-in was successful.
  Future<bool> signIn() async {
    try {
      final account = await _googleSignIn.signIn();
      if (account == null) {
        debugPrint('[GoogleAuth] User cancelled sign-in');
        return false;
      }
      _currentUser = account;
      await _onSignedIn(account);
      return true;
    } catch (e) {
      debugPrint('[GoogleAuth] Sign-in error: $e');
      return false;
    }
  }

  /// Signs out from Google and clears YouTube authentication.
  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
      _currentUser = null;
      _accessToken = null;
      _tokenExpiry = null;
      await _onSignedOut();
    } catch (e) {
      debugPrint('[GoogleAuth] Sign-out error: $e');
    }
  }

  /// Disconnects the app from the Google account (revokes permissions).
  Future<void> disconnect() async {
    try {
      await _googleSignIn.disconnect();
      _currentUser = null;
      _accessToken = null;
      _tokenExpiry = null;
      await _onSignedOut();
    } catch (e) {
      debugPrint('[GoogleAuth] Disconnect error: $e');
    }
  }

  // ──────────────────── Internal ────────────────────

  Future<void> _onSignedIn(GoogleSignInAccount account) async {
    debugPrint('[GoogleAuth] Signed in as ${account.email}');

    // Persist auth state using flutter_secure_storage (encrypted, not plain text)
    await _secureStorage.write(key: _prefSignedIn, value: 'true');
    await _secureStorage.write(key: _prefUserEmail, value: account.email);
    await _secureStorage.write(key: _prefUserName, value: account.displayName ?? '');
    await _secureStorage.write(key: _prefPhotoUrl, value: account.photoUrl ?? '');

    // Get fresh access token
    final token = await getAccessToken();
    if (token != null) {
      // Authenticate YouTube with the OAuth token
      YoutubeService.signInWithOAuth(token);
      debugPrint('[GoogleAuth] YouTube authenticated via OAuth token');
    }

    _authStateController.add(true);
  }

  Future<void> _onSignedOut() async {
    debugPrint('[GoogleAuth] Signed out');

    await _secureStorage.write(key: _prefSignedIn, value: 'false');
    await _secureStorage.delete(key: _prefUserEmail);
    await _secureStorage.delete(key: _prefUserName);
    await _secureStorage.delete(key: _prefPhotoUrl);

    // Clear YouTube authentication
    YoutubeService.signOut();

    _authStateController.add(false);
  }

  /// Restores persisted auth state (called before silent sign-in).
  Future<Map<String, String?>> getPersistedUserInfo() async {
    return {
      'email': await _secureStorage.read(key: _prefUserEmail),
      'name': await _secureStorage.read(key: _prefUserName),
      'photoUrl': await _secureStorage.read(key: _prefPhotoUrl),
    };
  }

  void dispose() {
    _authStateController.close();
  }
}