import 'package:flutter_test/flutter_test.dart';
import 'package:photos_vault/storage/container_path.dart';

void main() {
  const now =
      '/var/mobile/Containers/Data/Application/'
      'FAFBE958-7C98-46EC-A8E9-85C6F37BB2C5';
  const before =
      '/var/mobile/Containers/Data/Application/'
      '30B35B6F-4CD3-4820-9BB5-8CBAE4592AAC';

  test('a path into an old container moves onto this one', () {
    expect(
      rebaseContainerPath(
        '$before/Library/Application Support/p25.jpg',
        container: now,
      ),
      '$now/Library/Application Support/p25.jpg',
    );
  });

  test('a current path, a foreign path and null are left alone', () {
    const current = '$now/Documents/a.jpg';
    expect(rebaseContainerPath(current, container: now), current);
    expect(rebaseContainerPath('/tmp/a.jpg', container: now), '/tmp/a.jpg');
    expect(rebaseContainerPath(null, container: now), isNull);
  });
}
