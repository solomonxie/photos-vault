import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

/// AES-256-CTR, PBKDF2 and HKDF for the private album, on the platform's
/// own crypto rather than a package.
///
/// The app ships under a 33 MB budget with ~0.8 MB of headroom, and every
/// pure-Dart AES implementation spends a slice of that on something iOS
/// already has in hardware. So: `dart:ffi` straight to CommonCrypto, which
/// is in libSystem on every iPhone and every Mac (so tests reach the real
/// thing too). HMAC stays on `crypto`, already a dependency and fast
/// enough.
///
/// Counter mode, so encrypting and decrypting are the same operation and
/// nothing has to be padded to a block. Authentication is a separate
/// HMAC-SHA256 over header+ciphertext — encrypt-then-MAC — rather than GCM,
/// whose CommonCrypto binding is awkward and whose one real advantage
/// (single pass) does not matter for a file already being streamed.
abstract class VaultCipher {
  /// Stretches a user-chosen passphrase. Deliberately slow.
  Uint8List deriveKey({
    required String passphrase,
    required Uint8List salt,
    required int iterations,
    int length = 32,
  });

  /// CTR both ways: [transform] of a transform is the input again.
  Uint8List transform({
    required Uint8List key,
    required Uint8List iv,
    required Uint8List data,
  });
}

/// Straight-line HKDF-SHA256 (RFC 5869). Cheap — no FFI needed, and it runs
/// once per album unlock, not per file.
Uint8List hkdf({
  required Uint8List key,
  required List<int> info,
  int length = 64,
  List<int> salt = const [],
}) {
  final prk = Hmac(sha256, salt.isEmpty ? Uint8List(32) : salt).convert(key);
  final out = BytesBuilder();
  var previous = <int>[];
  for (var counter = 1; out.length < length; counter++) {
    previous = Hmac(
      sha256,
      prk.bytes,
    ).convert([...previous, ...info, counter]).bytes;
    out.add(previous);
  }
  return Uint8List.sublistView(out.toBytes(), 0, length);
}

Uint8List vaultHmac(Uint8List key, List<int> data) =>
    Uint8List.fromList(Hmac(sha256, key).convert(data).bytes);

/// Constant-time compare, so a MAC check cannot be walked byte by byte.
bool bytesMatch(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

// CommonCrypto constants, from <CommonCrypto/CommonCryptor.h>.
const _kCCEncrypt = 0;
const _kCCAlgorithmAES = 0;
const _ccNoPadding = 0;
const _kCCModeCTR = 4;
const _kCCModeOptionCTRBigEndian = 2;
const _kCCPBKDF2 = 2;

/// 3, not 2 — 2 is SHA-224, and the resulting key is silently wrong.
const _kCCPRFHmacAlgSHA256 = 3;

typedef _PbkdfNative = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Pointer<ffi.Uint8>,
  ffi.Size,
  ffi.Pointer<ffi.Uint8>,
  ffi.Size,
  ffi.Uint32,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint8>,
  ffi.Size,
);
typedef _Pbkdf = int Function(
  int,
  ffi.Pointer<ffi.Uint8>,
  int,
  ffi.Pointer<ffi.Uint8>,
  int,
  int,
  int,
  ffi.Pointer<ffi.Uint8>,
  int,
);

typedef _CreateNative = ffi.Int32 Function(
  ffi.Uint32,
  ffi.Uint32,
  ffi.Uint32,
  ffi.Uint32,
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Size,
  ffi.Pointer<ffi.Void>,
  ffi.Size,
  ffi.Int32,
  ffi.Uint32,
  ffi.Pointer<ffi.Pointer<ffi.Void>>,
);
typedef _Create = int Function(
  int,
  int,
  int,
  int,
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
  int,
  ffi.Pointer<ffi.Void>,
  int,
  int,
  int,
  ffi.Pointer<ffi.Pointer<ffi.Void>>,
);

typedef _UpdateNative = ffi.Int32 Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Size,
  ffi.Pointer<ffi.Uint8>,
  ffi.Size,
  ffi.Pointer<ffi.Size>,
);
typedef _Update = int Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Uint8>,
  int,
  ffi.Pointer<ffi.Uint8>,
  int,
  ffi.Pointer<ffi.Size>,
);

typedef _ReleaseNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _Release = int Function(ffi.Pointer<ffi.Void>);

/// The default [VaultCipher]. Symbols come from the already-loaded process
/// image — libSystem carries CommonCrypto on both iOS and macOS, so there
/// is nothing to link and nothing to ship.
class PlatformCipher implements VaultCipher {
  PlatformCipher();

  static final ffi.DynamicLibrary _lib = ffi.DynamicLibrary.process();

  static final _pbkdf = _lib.lookupFunction<_PbkdfNative, _Pbkdf>(
    'CCKeyDerivationPBKDF',
  );
  static final _create = _lib.lookupFunction<_CreateNative, _Create>(
    'CCCryptorCreateWithMode',
  );
  static final _update = _lib.lookupFunction<_UpdateNative, _Update>(
    'CCCryptorUpdate',
  );
  static final _release = _lib.lookupFunction<_ReleaseNative, _Release>(
    'CCCryptorRelease',
  );

  @override
  Uint8List deriveKey({
    required String passphrase,
    required Uint8List salt,
    required int iterations,
    int length = 32,
  }) {
    final password = utf8.encode(passphrase);
    final passwordPtr = calloc<ffi.Uint8>(password.length);
    final saltPtr = calloc<ffi.Uint8>(salt.length);
    final outPtr = calloc<ffi.Uint8>(length);
    try {
      passwordPtr.asTypedList(password.length).setAll(0, password);
      saltPtr.asTypedList(salt.length).setAll(0, salt);
      final status = _pbkdf(
        _kCCPBKDF2,
        passwordPtr,
        password.length,
        saltPtr,
        salt.length,
        _kCCPRFHmacAlgSHA256,
        iterations,
        outPtr,
        length,
      );
      if (status != 0) {
        throw StateError('CCKeyDerivationPBKDF failed: $status');
      }
      return Uint8List.fromList(outPtr.asTypedList(length));
    } finally {
      calloc
        ..free(passwordPtr)
        ..free(saltPtr)
        ..free(outPtr);
    }
  }

  @override
  Uint8List transform({
    required Uint8List key,
    required Uint8List iv,
    required Uint8List data,
  }) {
    if (key.length != 32) throw ArgumentError('key must be 32 bytes');
    if (iv.length != 16) throw ArgumentError('iv must be 16 bytes');
    if (data.isEmpty) return Uint8List(0);

    final keyPtr = calloc<ffi.Uint8>(key.length);
    final ivPtr = calloc<ffi.Uint8>(iv.length);
    final inPtr = calloc<ffi.Uint8>(data.length);
    final outPtr = calloc<ffi.Uint8>(data.length);
    final movedPtr = calloc<ffi.Size>();
    final cryptorPtr = calloc<ffi.Pointer<ffi.Void>>();
    try {
      keyPtr.asTypedList(key.length).setAll(0, key);
      ivPtr.asTypedList(iv.length).setAll(0, iv);
      inPtr.asTypedList(data.length).setAll(0, data);

      var status = _create(
        _kCCEncrypt,
        _kCCModeCTR,
        _kCCAlgorithmAES,
        _ccNoPadding,
        ivPtr,
        keyPtr,
        key.length,
        ffi.nullptr,
        0,
        0,
        _kCCModeOptionCTRBigEndian,
        cryptorPtr,
      );
      if (status != 0) {
        throw StateError('CCCryptorCreateWithMode failed: $status');
      }
      try {
        status = _update(
          cryptorPtr.value,
          inPtr,
          data.length,
          outPtr,
          data.length,
          movedPtr,
        );
        if (status != 0) throw StateError('CCCryptorUpdate failed: $status');
        return Uint8List.fromList(outPtr.asTypedList(movedPtr.value));
      } finally {
        _release(cryptorPtr.value);
      }
    } finally {
      calloc
        ..free(keyPtr)
        ..free(ivPtr)
        ..free(inPtr)
        ..free(outPtr)
        ..free(movedPtr)
        ..free(cryptorPtr);
    }
  }
}
