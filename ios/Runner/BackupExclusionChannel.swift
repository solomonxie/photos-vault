import Flutter
import Foundation

/// Marks a directory as excluded from the iOS device backup.
///
/// The private side of this app needs somewhere that is **both** durable and
/// out of the backup, and iOS offers no directory that is both by default:
///
/// - `Library/Application Support` survives forever and is backed up.
/// - `Library/Caches` is out of the backup and the OS may purge it.
///
/// An offline-first vault cannot live in a directory the system is entitled
/// to empty, and tens of gigabytes of hidden photos must not ride into the
/// owner's iCloud backup and eat their quota. So: Application Support, with
/// `isExcludedFromBackupKey` set on the directory, which every file created
/// inside it then inherits.
///
/// Setting it is idempotent and cheap, so Dart sets it every time the
/// directory is opened rather than trying to remember whether it did.
class BackupExclusionChannel {
  static let name = "byo.photos/backup_exclusion"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: name,
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      handle(call, result)
    }
  }

  private static func handle(
    _ call: FlutterMethodCall,
    _ result: @escaping FlutterResult
  ) {
    switch call.method {
    case "exclude":
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String
      else {
        result(
          FlutterError(
            code: "bad_arguments",
            message: "exclude needs a path",
            details: nil
          )
        )
        return
      }
      var url = URL(fileURLWithPath: path)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      do {
        try url.setResourceValues(values)
        result(true)
      } catch {
        // Reported rather than thrown: the directory is still usable, it
        // will just be in the backup, and the caller decides what to say.
        result(false)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
