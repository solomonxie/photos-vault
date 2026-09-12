import 'package:file_picker/file_picker.dart';

/// Opens the native folder picker (Files app / iCloud Drive on iOS).
abstract class FolderPicker {
  /// Returns the picked folder's path, or null if the user cancelled.
  Future<String?> pickFolder();
}

class NativeFolderPicker implements FolderPicker {
  const NativeFolderPicker();

  @override
  Future<String?> pickFolder() => FilePicker.getDirectoryPath();
}
