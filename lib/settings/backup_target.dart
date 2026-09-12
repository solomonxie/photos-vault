library;

part 'local_folder_backup_target.dart';
part 's3_backup_target.dart';

/// One configured destination the user backs photos up to. The app supports
/// a list of these, mixing kinds freely (e.g. an S3 bucket plus an iCloud
/// Drive folder).
sealed class BackupTarget {
  const BackupTarget({required this.id});

  final String id;

  Map<String, dynamic> toJson();

  static BackupTarget fromJson(Map<String, dynamic> json) {
    switch (json['type'] as String?) {
      case LocalFolderBackupTarget.jsonType:
        return LocalFolderBackupTarget.fromJson(json);
      case S3BackupTarget.jsonType:
      default:
        return S3BackupTarget.fromJson(json);
    }
  }
}
