import 'package:back_your_own_photos/settings/local_folder_connectivity.dart';
import 'package:back_your_own_photos/settings/security_scoped_bookmark.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeResolver implements SecurityScopedBookmarkResolver {
  _FakeResolver({this.createThrows = false, this.resolvesTo});

  final bool createThrows;
  final String? resolvesTo;
  String? stoppedPath;

  @override
  Future<String> createBookmark(String path) async {
    if (createThrows) throw StateError('boom');
    return 'bookmark-for-$path';
  }

  @override
  Future<String?> resolveAndStartAccess(String bookmarkData) async => resolvesTo;

  @override
  Future<void> stopAccess(String path) async => stoppedPath = path;
}

void main() {
  test('ok when the bookmark resolves and opens', () async {
    final resolver = _FakeResolver(resolvesTo: '/picked/folder');
    final result = await checkFolderAccess(path: '/picked/folder', resolver: resolver);

    expect(result.isOk, isTrue);
    expect(result.bookmarkData, 'bookmark-for-/picked/folder');
    expect(resolver.stoppedPath, '/picked/folder');
  });

  test('cannotOpen when resolving the freshly-created bookmark fails', () async {
    final resolver = _FakeResolver(resolvesTo: null);
    final result = await checkFolderAccess(path: '/picked/folder', resolver: resolver);

    expect(result.isOk, isFalse);
    expect(result.outcome, LocalFolderAccessOutcome.cannotOpen);
  });

  test('cannotOpen when bookmark creation throws', () async {
    final resolver = _FakeResolver(createThrows: true);
    final result = await checkFolderAccess(path: '/picked/folder', resolver: resolver);

    expect(result.isOk, isFalse);
  });
}
