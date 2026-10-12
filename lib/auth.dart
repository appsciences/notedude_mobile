import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

class AuthUser {
  const AuthUser({required this.uid, this.email, this.displayName});

  final String uid;
  final String? email;
  final String? displayName;

  /// What to show the person: the address if there is one, else their name.
  String get label => email ?? displayName ?? uid;
}

class AuthException implements Exception {
  const AuthException(this.message) : cancelled = false;

  /// The person dismissed the Google prompt. Not an error to report.
  const AuthException.cancelled()
    : message = 'Sign-in cancelled.',
      cancelled = true;

  final String message;
  final bool cancelled;

  @override
  String toString() => message;
}

/// Identity for the NoteDude API, which is secured by Firebase Auth.
abstract interface class AuthService {
  AuthUser? get currentUser;

  /// Emits the signed-in user, or null after sign-out. Does not replay the
  /// current user; read [currentUser] for the initial value.
  Stream<AuthUser?> get userChanges;

  Future<void> signInWithGoogle();

  Future<void> signOut();

  /// A Firebase ID token for `Authorization: Bearer` calls, or null when
  /// signed out. Pass [forceRefresh] after the API rejects a token.
  Future<String?> idToken({bool forceRefresh = false});
}

class FirebaseAuthService implements AuthService {
  FirebaseAuthService({FirebaseAuth? auth, GoogleSignIn? googleSignIn})
    : _auth = auth ?? FirebaseAuth.instance,
      _google = googleSignIn ?? GoogleSignIn.instance;

  final FirebaseAuth _auth;
  final GoogleSignIn _google;
  Future<void>? _initialized;

  static AuthUser? _map(User? user) => user == null
      ? null
      : AuthUser(
          uid: user.uid,
          email: user.email,
          displayName: user.displayName,
        );

  @override
  AuthUser? get currentUser => _map(_auth.currentUser);

  @override
  Stream<AuthUser?> get userChanges => _auth.userChanges().map(_map);

  @override
  Future<void> signInWithGoogle() async {
    try {
      // Android reads the web client ID from the generated
      // default_web_client_id resource; iOS reads GoogleService-Info.plist.
      await (_initialized ??= _google.initialize());
      final account = await _google.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        throw const AuthException('Google did not return an ID token.');
      }
      await _auth.signInWithCredential(
        GoogleAuthProvider.credential(idToken: idToken),
      );
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        throw const AuthException.cancelled();
      }
      throw AuthException(error.description ?? error.code.name);
    } on FirebaseAuthException catch (error) {
      throw AuthException(error.message ?? error.code);
    }
  }

  @override
  Future<void> signOut() async {
    await _auth.signOut();
    try {
      await (_initialized ??= _google.initialize());
      await _google.signOut();
    } on GoogleSignInException {
      // Firebase is already signed out; a stale Google session is harmless.
    }
  }

  @override
  Future<String?> idToken({bool forceRefresh = false}) =>
      _auth.currentUser?.getIdToken(forceRefresh) ?? Future.value();
}
