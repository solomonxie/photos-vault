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
    case "writeBytes":
      guard let arguments = call.arguments as? [String: Any],
            let name = arguments["name"] as? String,
            let bytes = arguments["bytes"] as? FlutterStandardTypedData
      else {
        result(false)
        return
      }
      result(writeBytes(name: name, data: bytes.data))
    case "readLatest":
      result(readLatest())
    case "readLatestBytes":
      if let data = readLatestBytes() {
        result(FlutterStandardTypedData(bytes: data))
      } else {
        result(nil)
      }
    case "readBytes":
      guard let arguments = call.arguments as? [String: Any],
            let name = arguments["name"] as? String
      else {
        result(nil)
        return
      }
      if let data = readBytes(name: name) {
        result(FlutterStandardTypedData(bytes: data))
      } else {
        result(nil)
      }
    case "latestWriteAt":
      result(latestWriteAt())
    case "list":
      result(list())
    case "delete":
      guard let arguments = call.arguments as? [String: Any],
            let name = arguments["name"] as? String
      else {
        result(false)
        return
      }
      result(delete(name: name))
    case "beginBackgroundTask":
      DispatchQueue.main.async { result(beginTask()) }
    case "endBackgroundTask":
      let raw = (call.arguments as? [String: Any])?["id"] as? Int
      DispatchQueue.main.async {
        if let raw { endTask(raw) }
        result(nil)
      }
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

  private static func writeBytes(name: String, data: Data) -> Bool {
    guard let root = containerURL() else { return false }
    let file = root.appendingPathComponent(name)
    do {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      // Atomic, for the same reason the text write is: a half-written
      // snapshot that syncs is worse than no snapshot, because it looks
      // like one.
      try data.write(to: file, options: .atomic)
      return true
    } catch {
      return false
    }
  }

  /// Every file in the folder, by name. Pruning happens here rather than
  /// from the app's own records because the folder is the only thing that
  /// knows what is really up there — a device restored from a year-old
  /// backup has no idea.
  ///
  /// A file still only in iCloud (a new phone) lists as `.name.icloud`;
  /// it is reported as `name`, which is what reads and deletes take.
  private static func list() -> [String] {
    guard let root = containerURL() else { return [] }
    let files = (try? FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil
    )) ?? []
    let names = Set(files.map { itemName($0.lastPathComponent) })
    return names.filter { !$0.isEmpty }.sorted()
  }

  private static func itemName(_ listed: String) -> String {
    let suffix = ".icloud"
    guard listed.hasPrefix("."), listed.hasSuffix(suffix),
          listed.count > suffix.count
    else { return listed }
    return String(listed.dropFirst().dropLast(suffix.count))
  }

  /// Removes one file by name. `lastPathComponent` on the way in, so a
  /// name carrying `../` can't reach outside the app's own folder.
  private static func delete(name: String) -> Bool {
    guard let root = containerURL() else { return false }
    let file = root.appendingPathComponent(
      URL(fileURLWithPath: name).lastPathComponent
    )
    do {
      try FileManager.default.removeItem(at: file)
      return true
    } catch {
      // Not downloaded: only its placeholder is here.
      let placeholder = root.appendingPathComponent(
        "." + file.lastPathComponent + ".icloud"
      )
      return (try? FileManager.default.removeItem(at: placeholder)) != nil
    }
  }

  /// The newest snapshot of the given kind. Names sort by date — the app
  /// writes one `YYYYMMDD.zip` per day — so the last name is the newest
  /// file without having to stat every one of them.
  private static func latestFile(withExtension ext: String) -> URL? {
    guard let root = containerURL() else { return nil }
    guard let name = list()
      .filter({ URL(fileURLWithPath: $0).pathExtension == ext })
      .last
    else { return nil }
    return root.appendingPathComponent(name)
  }

  /// Whichever kind is newer. `.json` is the single rolling file older
  /// builds wrote; it stays readable so an upgrade doesn't lose the copy
  /// it already had.
  private static func latestFile() -> URL? {
    let zip = latestFile(withExtension: "zip")
    let json = latestFile(withExtension: "json")
    guard let zip else { return json }
    guard let json else { return zip }
    return modifiedAt(zip) >= modifiedAt(json) ? zip : json
  }

  private static func modifiedAt(_ file: URL) -> Date {
    let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
    return values?.contentModificationDate ?? .distantPast
  }

  private static func readLatest() -> String? {
    guard let file = latestFile(withExtension: "json"),
          let data = coordinatedData(at: file)
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func readLatestBytes() -> Data? {
    guard let file = latestFile(withExtension: "zip") else { return nil }
    return coordinatedData(at: file)
  }

  /// The file may be in the cloud and not yet on this device — exactly the
  /// fresh-install case this exists for. A coordinated read waits for
  /// iCloud to bring it down, where a plain read returns nothing; it is
  /// cancelled after [timeout] seconds.
  private static func coordinatedData(
    at file: URL,
    timeout: TimeInterval = 60
  ) -> Data? {
    try? FileManager.default.startDownloadingUbiquitousItem(at: file)
    let coordinator = NSFileCoordinator(filePresenter: nil)
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + timeout
    ) {
      coordinator.cancel()
    }
    var data: Data?
    var error: NSError?
    coordinator.coordinate(readingItemAt: file, options: [], error: &error) {
      url in
      data = try? Data(contentsOf: url)
    }
    return data
  }

  /// One archive by name. Which archive to restore from is a question the
  /// app answers — a pre-deletion copy outranks a newer daily one, and
  /// nothing about that is visible from here. `lastPathComponent` on the
  /// way in, as with `delete`, so a name carrying `../` can't reach
  /// outside the app's own folder.
  private static func readBytes(name: String) -> Data? {
    guard let root = containerURL() else { return nil }
    let file = root.appendingPathComponent(
      URL(fileURLWithPath: name).lastPathComponent
    )
    return coordinatedData(at: file)
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

  // MARK: - Background time

  /// Main thread only.
  private static var tasks: [Int: UIBackgroundTaskIdentifier] = [:]

  /// Time to finish the app-data copy after the app leaves the foreground.
  /// Nil when iOS grants none.
  private static func beginTask() -> Int? {
    let id = UIApplication.shared.beginBackgroundTask(
      withName: "app-data copy"
    ) {
      // Out of time: handed back, or iOS ends the app for holding it.
      endAllTasks()
    }
    guard id != .invalid else { return nil }
    tasks[id.rawValue] = id
    return id.rawValue
  }

  private static func endAllTasks() {
    for raw in Array(tasks.keys) { endTask(raw) }
  }

  private static func endTask(_ raw: Int) {
    guard let id = tasks.removeValue(forKey: raw) else { return }
    UIApplication.shared.endBackgroundTask(id)
  }
}
