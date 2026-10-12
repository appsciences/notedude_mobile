import 'dart:async';

import 'package:notedude_mobile/auth.dart';

class FakeAuth implements AuthService {
  FakeAuth({AuthUser? user}) : _user = user;

  static const person = AuthUser(
    uid: 'uid-1',
    email: 'leo@example.com',
    displayName: 'Leo',
  );

  final _controller = StreamController<AuthUser?>.broadcast();
  AuthUser? _user;
  Object? signInError;
  int signInCalls = 0;
  int signOutCalls = 0;

  @override
  AuthUser? get currentUser => _user;

  @override
  Stream<AuthUser?> get userChanges => _controller.stream;

  @override
  Future<void> signInWithGoogle() async {
    signInCalls++;
    final error = signInError;
    if (error != null) throw error;
    _user = person;
    _controller.add(_user);
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
    _user = null;
    _controller.add(null);
  }

  @override
  Future<String?> idToken({bool forceRefresh = false}) async =>
      _user == null ? null : 'token-for-${_user!.uid}';
}
