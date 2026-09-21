import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/vault/cipher.dart';

Uint8List hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

String toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final cipher = PlatformCipher();

  test('AES-256-CTR matches the NIST SP 800-38A F.5.5 vector', () {
    final out = cipher.transform(
      key: hex(
        '603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4',
      ),
      iv: hex('f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff'),
      data: hex('6bc1bee22e409f96e93d7e117393172a'),
    );
    expect(toHex(out), '601ec313775789a5b7a7f504bbf3d228');
  });

  test('transform is its own inverse, and 5 MB survives it', () {
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final iv = Uint8List.fromList(List.generate(16, (i) => 255 - i));
    final plain = Uint8List.fromList(
      List.generate(5 * 1024 * 1024, (i) => i % 251),
    );

    final encrypted = cipher.transform(key: key, iv: iv, data: plain);
    expect(encrypted, isNot(equals(plain)));
    expect(cipher.transform(key: key, iv: iv, data: encrypted), equals(plain));
  });

  test('PBKDF2-HMAC-SHA256 matches RFC 7914 vector', () {
    final out = cipher.deriveKey(
      passphrase: 'passwd',
      salt: Uint8List.fromList(utf8.encode('salt')),
      iterations: 1,
      length: 64,
    );
    expect(toHex(out.take(8).toList()), '55ac046e56e3089f');
  });

  test('a different passphrase derives a different key', () {
    final salt = Uint8List(16);
    final a = cipher.deriveKey(passphrase: 'one', salt: salt, iterations: 1000);
    final b = cipher.deriveKey(passphrase: 'two', salt: salt, iterations: 1000);
    expect(a, isNot(equals(b)));
    expect(a.length, 32);
  });

  test('hkdf is deterministic and separates by info', () {
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final a = hkdf(key: key, info: utf8.encode('album:1234'));
    expect(a.length, 64);
    expect(a, equals(hkdf(key: key, info: utf8.encode('album:1234'))));
    expect(a, isNot(equals(hkdf(key: key, info: utf8.encode('album:1235')))));
  });

  test('bytesMatch is length-safe', () {
    expect(bytesMatch([1, 2, 3], [1, 2, 3]), isTrue);
    expect(bytesMatch([1, 2, 3], [1, 2, 4]), isFalse);
    expect(bytesMatch([1, 2, 3], [1, 2]), isFalse);
  });
}
