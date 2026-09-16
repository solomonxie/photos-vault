/// Object storage backend a [S3BackupTarget]-like entry could live on.
/// Only [s3] is wired up today — the others are listed so the picker in
/// Add Backup shows the roadmap, disabled until each one ships its own
/// credential fields and uploader.
enum BackupStorageType { s3, googleCloudStorage, azureBlob, backblazeB2 }

class BackupStorageTypeMeta {
  const BackupStorageTypeMeta({
    required this.type,
    required this.name,
    required this.available,
  });

  final BackupStorageType type;
  final String name;
  final bool available;
}

const backupStorageTypes = <BackupStorageTypeMeta>[
  BackupStorageTypeMeta(
    type: BackupStorageType.s3,
    name: 'Amazon S3',
    available: true,
  ),
  BackupStorageTypeMeta(
    type: BackupStorageType.googleCloudStorage,
    name: 'Google Cloud Storage',
    available: false,
  ),
  BackupStorageTypeMeta(
    type: BackupStorageType.azureBlob,
    name: 'Azure Blob Storage',
    available: false,
  ),
  BackupStorageTypeMeta(
    type: BackupStorageType.backblazeB2,
    name: 'Backblaze B2',
    available: false,
  ),
];
