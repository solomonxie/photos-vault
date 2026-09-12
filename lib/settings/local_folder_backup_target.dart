part of 'backup_target.dart';

/// A local folder (typically under iCloud Drive) the user backs photos up
/// to directly, no S3 account needed. `bookmarkData` is an opaque,
/// platform-persisted security-scoped bookmark (iOS) resolved back to a
/// writable folder at backup time — see T1.7 for how it's produced.
class LocalFolderBackupTarget extends BackupTarget {
  const LocalFolderBackupTarget({
    required super.id,
    required this.displayName,
    required this.bookmarkData,
    this.prefix = '',
  });

  static const jsonType = 'localFolder';

  final String displayName;
  final String bookmarkData;
  final String prefix;

  @override
  Map<String, dynamic> toJson() => {
    'type': jsonType,
    'id': id,
    'displayName': displayName,
    'bookmarkData': bookmarkData,
    'prefix': prefix,
  };

  factory LocalFolderBackupTarget.fromJson(Map<String, dynamic> json) => LocalFolderBackupTarget(
    id: json['id'] as String,
    displayName: json['displayName'] as String? ?? '',
    bookmarkData: json['bookmarkData'] as String? ?? '',
    prefix: json['prefix'] as String? ?? '',
  );
}
