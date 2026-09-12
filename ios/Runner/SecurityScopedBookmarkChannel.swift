import Flutter
import Foundation

/// Native side of `lib/settings/security_scoped_bookmark.dart` — creates and
/// resolves iOS security-scoped bookmarks so the app keeps access to a
/// user-picked folder (outside its own sandbox) across restarts. See T1.7/T1.8.
class SecurityScopedBookmarkChannel: NSObject, FlutterPlugin {
  /// Paths currently under an active `startAccessingSecurityScopedResource()`
  /// call, keyed by path, so `stopAccess` can end the scope on the exact URL
  /// instance that started it.
  private var accessingURLs: [String: URL] = [:]

  static func register(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "SecurityScopedBookmarkChannel") else { return }
    register(with: registrar)
  }

  /// Satisfies `FlutterPlugin`'s required entry point (used if this were
  /// ever registered via the normal generated-plugin path instead).
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "back_your_own_photos/security_scoped_bookmark",
      binaryMessenger: registrar.messenger()
    )
    let instance = SecurityScopedBookmarkChannel()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "bad_args", message: "Expected a map argument", details: nil))
      return
    }

    switch call.method {
    case "createBookmark":
      guard let path = args["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "Missing path", details: nil))
        return
      }
      createBookmark(path: path, result: result)
    case "resolveAndStartAccess":
      guard let bookmarkData = args["bookmarkData"] as? String else {
        result(FlutterError(code: "bad_args", message: "Missing bookmarkData", details: nil))
        return
      }
      resolveAndStartAccess(bookmarkData: bookmarkData, result: result)
    case "stopAccess":
      guard let path = args["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "Missing path", details: nil))
        return
      }
      stopAccess(path: path, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func createBookmark(path: String, result: @escaping FlutterResult) {
    let url = URL(fileURLWithPath: path)
    let didStart = url.startAccessingSecurityScopedResource()
    defer { if didStart { url.stopAccessingSecurityScopedResource() } }
    do {
      let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
      result(data.base64EncodedString())
    } catch {
      result(FlutterError(code: "bookmark_failed", message: error.localizedDescription, details: nil))
    }
  }

  private func resolveAndStartAccess(bookmarkData: String, result: @escaping FlutterResult) {
    guard let data = Data(base64Encoded: bookmarkData) else {
      result(nil)
      return
    }
    var isStale = false
    let url: URL
    do {
      url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
    } catch {
      // Stale/revoked bookmark — callers must prompt a re-pick (T1.8), not fail silently.
      result(nil)
      return
    }
    guard url.startAccessingSecurityScopedResource() else {
      result(nil)
      return
    }
    accessingURLs[url.path] = url
    result(url.path)
  }

  private func stopAccess(path: String, result: @escaping FlutterResult) {
    if let url = accessingURLs.removeValue(forKey: path) {
      url.stopAccessingSecurityScopedResource()
    }
    result(nil)
  }
}
