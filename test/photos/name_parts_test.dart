import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/name_parts.dart';

void main() {
  test('spaced names split into first, middle and last', () {
    expect(suggestNameParts('Mia Jane Wu'), (
      first: 'Mia',
      middle: 'Jane',
      last: 'Wu',
    ));
    expect(suggestNameParts('Mia Wu'), (first: 'Mia', middle: '', last: 'Wu'));
    expect(suggestNameParts('Mia'), (first: 'Mia', middle: '', last: ''));
  });

  test('Chinese names put the surname first, compound ones too', () {
    expect(suggestNameParts('王小明'), (first: '小明', middle: '', last: '王'));
    expect(suggestNameParts('欧阳娜娜'), (first: '娜娜', middle: '', last: '欧阳'));
  });
}
