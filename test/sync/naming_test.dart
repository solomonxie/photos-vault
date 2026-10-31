import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/vault/object_key.dart';

void main() {
  test(
    'a browser upload id hashes as extension/test/upload.test.ts expects',
    () {
      expect(ordinaryNameHash('web:3f2b'), '05ac64381c79503f099ed7213dbdf29b');
      expect(objectStamp(DateTime(2026, 10, 28, 16, 13, 5)), '20261028161305');
    },
  );
}
