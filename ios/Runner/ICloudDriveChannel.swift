import Flutter
import UIKit

/// The app's own folder in iCloud Drive: check whether it's usable, write a
/// file, read the newest one back.
///
/// Everything here is file-at-a-time on purpose. The live sqlite database
/// must never be the thing iCloud syncs — cloud drives know nothing about
/// write-ahead logs or journal sidecars, and pointing one at a working
/// database buys corruption and `library 2.db` conflict copies. What goes
/// up is an exported snapshot, which is just bytes.
class ICloudDriveChannel {
  static let name = "byo.photos/icloud"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: name,
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      // Reaching the ubiquity container touches the filesystem and can
      // block while iCloud thinks about it.
      DispatchQueue.global(qos: .utility).async {
        handle(call, result)
      }
    }
  }

  private static func handle(
    _ call: FlutterMethodCall,
    _ result: @escaping FlutterResult
  ) {
    switch call.method {
    case "status":
      result(status())
    case "write":
      guard let arguments = call.arguments as? [String: Any],
            let name = arguments["name"] as? String,
            let contents = arguments["contents"] as? String
      else {
        result(false)
        return
      }
      result(write(name: name, contents: contents))
    case "readLatest":
      result(readLatest())
    case "latestWriteAt":
      result(latestWriteAt())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - State

  /// The four reasons a container comes back nil, in the order that makes
  /// each answer trustworthy.
  ///
  /// The account check has to come *after* the entitlement check:
  /// `ubiquityIdentityToken` itself needs the iCloud entitlement, so in an
  /// unentitled build it reads nil and is indistinguishable from a signed
  /// out user. Asking in the other order tells someone who is already
  /// signed in to go and sign in.
  private static func status() -> String {
    if containerURL() != nil { return "available" }
    // Only a build we can *see* the capability on gets to claim one of the
    // states that might fix itself. Anything else is reported as the build's
    // fault, which is the one answer that asks nothing of the user — telling
    // someone to try again shortly, when no amount of shortly will help, is
    // the failure this whole enum exists to avoid.
    guard isEntitled() else { return "notEntitled" }
    if FileManager.default.ubiquityIdentityToken == nil { return "driveOff" }
    return "notReady"
  }

  private static func containerURL() -> URL? {
    FileManager.default.url(forUbiquityContainerIdentifier: nil)?
      .appendingPathComponent("Documents", isDirectory: true)
  }

  /// Reads the capability out of the embedded provisioning profile.
  /// `SecTaskCopyValueForEntitlement` isn't in the iOS SDK, so the profile
  /// is the only way to ask a build about itself.
  ///
  /// No readable profile counts as *not* entitled. The generous reading —
  /// assume an App Store build, which would be entitled or it wouldn't have
  /// shipped — was tried, and on a development build that couldn't reach
  /// the profile it produced "iCloud isn't ready yet, try again shortly"
  /// forever. A build that can't prove it holds the capability shouldn't
  /// promise anything on its behalf.
  private static func isEntitled() -> Bool {
    // Straight off the bundle rather than through `forResource:`, which
    // searches the resource directory and can miss a file that sits at the
    // bundle root.
    let url = Bundle.main.bundleURL
      .appendingPathComponent("embedded.mobileprovision")
    guard let data = try? Data(contentsOf: url) else { return false }
    guard let raw = String(data: data, encoding: .isoLatin1),
          let start = raw.range(of: "<?xml"),
          let end = raw.range(of: "</plist>")
    else { return false }
    let plist = String(raw[start.lowerBound..<end.upperBound])
    guard let plistData = plist.data(using: .isoLatin1),
          let parsed = try? PropertyListSerialization.propertyList(
            from: plistData, options: [], format: nil
          ) as? [String: Any],
          let entitlements = parsed["Entitlements"] as? [String: Any]
    else { return false }
    // Present *and* naming a container. A profile for an App ID with the
    // iCloud capability available but no container registered carries the
    // key with an empty array — which is not a build that can ever reach a
    // container, and reporting it as "not ready yet" invites the user to
    // wait for something that will never happen.
    let containers = entitlements[
      "com.apple.developer.icloud-container-identifiers"
    ] as? [String]
    return !(containers ?? []).isEmpty
  }

  // MARK: - Files

  private static func write(name: String, contents: String) -> Bool {
    guard let root = containerURL() else { return false }
    let file = root.appendingPathComponent(name)
    do {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      // Atomic: a half-written snapshot that syncs is worse than no
      // snapshot, because it looks like one.
      try contents.write(to: file, atomically: true, encoding: .utf8)
      return true
    } catch {
      return false
    }
  }

  /// The newest — and only — snapshot. One file, overwritten: what this is
  /// for is surviving the app being deleted, and one current copy does that
  /// completely.
  private static func latestFile() -> URL? {
    guard let root = containerURL() else { return nil }
    let files = (try? FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil
    )) ?? []
    return files
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .last
  }

  private static func readLatest() -> String? {
    guard let file = latestFile() else { return nil }
    // The file may be in the cloud and not yet on this device — which is
    // exactly the fresh-install case this exists for.
    try? FileManager.default.startDownloadingUbiquitousItem(at: file)
    return try? String(contentsOf: file, encoding: .utf8)
  }

  private static func latestWriteAt() -> Int? {
    guard let file = latestFile(),
          let values = try? file.resourceValues(
            forKeys: [.contentModificationDateKey]
          ),
          let date = values.contentModificationDate
    else { return nil }
    return Int(date.timeIntervalSince1970 * 1000)
  }
}
