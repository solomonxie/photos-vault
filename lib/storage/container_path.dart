import 'dart:io';

/// iOS can give an app's data container a new folder name — a reinstall, a
/// restore onto another phone — so an absolute path an earlier run stored
/// points into a folder that no longer exists. Rebased onto this run's.
String? rebaseContainerPath(String? path, {String? container}) {
  if (path == null) return null;
  final current = container ?? _currentContainer;
  if (current == null) return path;
  final match = _container.firstMatch(path);
  final old = match?.group(1);
  if (old == null || old == current) return path;
  return '$current${path.substring(old.length)}';
}

final _container = RegExp(
  r'^(.*/Containers/Data/Application/[0-9A-Fa-f-]{36})/',
);

/// From the temp directory, which iOS puts inside the container: no I/O.
final String? _currentContainer = _container
    .firstMatch('${Directory.systemTemp.path}/')
    ?.group(1);
