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

/// This run's container folder name, or null outside one.
String? get currentContainerId {
  final current = _currentContainer;
  return current?.substring(current.length - 36);
}

/// Where a path's container folder name starts — the marker `GLOB`s on.
const containerMarker = '/Containers/Data/Application/';

/// Whether [path] is inside an app container (any run's).
bool inAContainer(String path) => _container.hasMatch(path);
