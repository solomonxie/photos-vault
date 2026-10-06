import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/demo/demo_bucket.dart';
import 'package:photos_vault/demo/demo_flag.dart';
import 'package:photos_vault/settings/s3_backup_target.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const target = S3BackupTarget(
    id: 'd',
    accessKeyId: 'DEMO',
    secretAccessKey: 'DEMO',
    region: 'us-west-2',
    bucket: DemoBucket.bucket,
    prefix: DemoBucket.prefix,
  );

  setUp(() => DemoFlag.active = true);
  tearDown(() => DemoFlag.active = false);

  test('only demo mode owns the demo bucket', () {
    expect(DemoBucket.owns(target), isTrue);
    DemoFlag.active = false;
    expect(DemoBucket.owns(target), isFalse);
  });

  test('lists folders, then the backed-up photos, with no network', () async {
    final root = (await DemoBucket.list(DemoBucket.prefix)).page!;
    expect(root.folders, [
      '${DemoBucket.prefix}originals/',
      '${DemoBucket.prefix}thumbnails/',
    ]);

    final originals = (await DemoBucket.list('${DemoBucket.prefix}originals/'))
        .page!;
    expect(originals.objects, isNotEmpty);
    expect(originals.objects.every((o) => o.key.endsWith('.jpg')), isTrue);
  });

  test('an object previews as a real image', () async {
    final originals = (await DemoBucket.list('${DemoBucket.prefix}originals/'))
        .page!;

    final bytes = await DemoBucket.bytesOf(originals.objects.first.key);

    expect(bytes, isNotNull);
    expect(bytes!.sublist(0, 2), [0xFF, 0xD8]);
  });
}
