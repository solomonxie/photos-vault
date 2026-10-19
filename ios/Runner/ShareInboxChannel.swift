import Flutter
import Foundation

/// Where the share extension leaves what was shared (`ShareExtension/`):
/// the App Group's `ShareInbox`, out of the device backup. Null when the
/// build isn't signed for the group.
class ShareInboxChannel {
  static func register(with registrar: FlutterPluginRegistrar) {
    FlutterMethodChannel(
      name: "byo.photos/share_inbox",
      binaryMessenger: registrar.messenger()
    ).setMethodCallHandler { call, result in
      guard call.method == "path" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as? String,
            let root = FileManager.default.containerURL(
              forSecurityApplicationGroupIdentifier: group
            )
      else {
        result(nil)
        return
      }
      var dir = root.appendingPathComponent("ShareInbox", isDirectory: true)
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try? dir.setResourceValues(values)
      result(dir.path)
    }
  }
}
