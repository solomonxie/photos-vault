import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/photos/person.dart';
import 'package:photos_vault/viewer/profile_details.dart';

PersonCustomField _f(String label, String value) =>
    PersonCustomField(label: label, value: value);

void main() {
  test('same-named fields from several imports read as one row each', () {
    final groups = groupDetails([
      _f('Relation to me', 'friend'),
      _f('First record', '2008-10-03 (life-logs)'),
      _f('Last record', '2011-03-09 (life-logs)'),
      _f('Phones', '+86 1, +86 2'),
      _f('QQ groups', 'QQ group A'),
      _f('Relation to me', 'teacher'),
      _f('Messages', 'SMS 20, QQ 61'),
      _f('First record', '2007-05-01 (QQ)'),
      _f('Last record', '2015-05-07 (QQ)'),
      _f('Phones', '+86 2'),
      _f('QQ groups', 'QQ group B'),
    ]);
    final general = groups[DetailGroup.general]!;
    expect([for (final r in general) r.label], ['Relation to me', 'QQ groups']);
    expect(general.first.values, ['friend', 'teacher']);
    expect(general.first.fields, [0, 5]);
    expect(general.last.values, ['QQ group A', 'QQ group B']);

    expect(groups[DetailGroup.contact]!.single.values, ['+86 1', '+86 2']);

    final records = {
      for (final r in groups[DetailGroup.records]!) r.label: r.values,
    };
    expect(records['First record'], ['2007-05-01']);
    expect(records['Last record'], ['2015-05-07']);
    expect(records['Messages'], ['SMS 20', 'QQ 61']);
  });
}
