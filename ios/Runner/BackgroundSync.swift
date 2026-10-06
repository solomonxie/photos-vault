import BackgroundTasks
import Flutter
import UIKit

/// The nightly pass iOS grants a processing task: a second, screenless
/// Flutter engine runs the Dart `backgroundSync` entrypoint, which uploads
/// what is pending and calls `done`. iOS decides when (usually overnight, on
/// power and Wi-Fi) and whether at all.
enum BackgroundSync {
  static var identifier: String {
    (Bundle.main.bundleIdentifier ?? "") + ".sync"
  }

  private static var engine: FlutterEngine?
  private static var channel: FlutterMethodChannel?

  /// Before `didFinishLaunching` returns, or iOS refuses it.
  static func register() {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
      guard let task = task as? BGProcessingTask else { return }
      DispatchQueue.main.async { run(task) }
    }
  }

  static func schedule() {
    let request = BGProcessingTaskRequest(identifier: identifier)
    request.requiresNetworkConnectivity = true
    request.requiresExternalPower = true
    request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
    try? BGTaskScheduler.shared.submit(request)
  }

  private static func run(_ task: BGProcessingTask) {
    schedule()
    let engine = FlutterEngine(name: "background_sync", project: nil, allowHeadlessExecution: true)
    let channel = FlutterMethodChannel(
      name: "byo.photos/background_sync",
      binaryMessenger: engine.binaryMessenger
    )
    self.engine = engine
    self.channel = channel

    var finished = false
    func finish(_ success: Bool) {
      if finished { return }
      finished = true
      task.setTaskCompleted(success: success)
      self.channel = nil
      self.engine?.destroyContext()
      self.engine = nil
    }

    channel.setMethodCallHandler { call, result in
      if call.method == "done" {
        finish((call.arguments as? Bool) ?? false)
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    task.expirationHandler = {
      DispatchQueue.main.async {
        channel.invokeMethod("expire", arguments: nil)
        // Dart is asked to stop; iOS gets the task back either way.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish(false) }
      }
    }

    guard engine.run(withEntrypoint: "backgroundSync") else {
      finish(false)
      return
    }
    GeneratedPluginRegistrant.register(with: engine)
    // The channels the upload and thumbnail path reaches. Hidden photos,
    // Vision and the privacy cover are not part of a background pass.
    if let registrar = engine.registrar(forPlugin: "ImageEncodeChannel") {
      ImageEncodeChannel.register(with: registrar)
    }
    if let registrar = engine.registrar(forPlugin: "StillVideoChannel") {
      StillVideoChannel.register(with: registrar)
    }
    if let registrar = engine.registrar(forPlugin: "BackupExclusionChannel") {
      BackupExclusionChannel.register(with: registrar)
    }
  }
}
