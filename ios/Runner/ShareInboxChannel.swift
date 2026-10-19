import Flutter
import Foundation
import Security

/// Where the share extension leaves what was shared (`ShareExtension/`):
/// the App Group's `ShareInbox`, out of the device backup. `path` is null
/// when the build isn't signed for the group. `readCode`/`forgetCode`: a
/// hidden batch's code, deleted once the batch is filed.
class ShareInboxChannel {
  static func register(with registrar: FlutterPluginRegistrar) {
    FlutterMethodChannel(
      name: "byo.photos/share_inbox",
      binaryMessenger: registrar.messenger()
    ).setMethodCallHandler { call, result in
      guard let id = Bundle.main.bundleIdentifier else {
        result(nil)
        return
      }
      let group = "group." + id
      switch call.method {
      case "path":
        result(inboxPath(group))
      case "readCode", "forgetCode":
        guard let ref = (call.arguments as? [String: Any])?["ref"] as? String
        else {
          result(nil)
          return
        }
        let query = codeQuery(ref, group: group)
        if call.method == "forgetCode" {
          SecItemDelete(query as CFDictionary)
          result(nil)
        } else {
          result(readCode(query))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func inboxPath(_ group: String) -> String? {
    guard let root = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: group
    ) else { return nil }
    var dir = root.appendingPathComponent("ShareInbox", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? dir.setResourceValues(values)
    return dir.path
  }

  private static func codeQuery(_ ref: String, group: String) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: "share-inbox",
      kSecAttrAccount: ref,
      kSecAttrAccessGroup: group,
    ]
  }

  private static func readCode(_ query: [CFString: Any]) -> String? {
    var lookup = query
    lookup[kSecReturnData] = true
    var item: CFTypeRef?
    guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
