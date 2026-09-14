import 'dart:convert';

import 'package:crypto/crypto.dart';

/// SHA-256 hex digest of a passcode — shared by [PrivateAlbumStore] (where
/// the hash doubles as the album's id) and person-profile locks (T7.4),
/// so a `sqflite` dump never lists the raw passcodes in use.
String hashPasscode(String passcode) => sha256.convert(utf8.encode(passcode)).toString();
