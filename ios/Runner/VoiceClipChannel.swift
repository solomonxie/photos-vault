import AVFoundation
import Flutter

/// Plays one chat voice clip at a time: `play(path)` → its length in
/// seconds, `stop`, and `finished` back to Dart when it runs out.
class VoiceClipChannel: NSObject, AVAudioPlayerDelegate {
  static let name = "byo.photos/voice_clip"
  private static let shared = VoiceClipChannel()

  private var channel: FlutterMethodChannel?
  private var player: AVAudioPlayer?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: name,
      binaryMessenger: registrar.messenger()
    )
    shared.channel = channel
    channel.setMethodCallHandler { call, result in
      shared.handle(call, result)
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "play":
      guard let path = call.arguments as? String else {
        result(FlutterError(code: "args", message: "path", details: nil))
        return
      }
      stop()
      do {
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
        player.delegate = self
        player.play()
        self.player = player
        result(player.duration)
      } catch {
        result(FlutterError(code: "play", message: error.localizedDescription, details: nil))
      }
    case "stop":
      stop()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func stop() {
    player?.stop()
    player = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    guard player === self.player else { return }
    stop()
    channel?.invokeMethod("finished", arguments: nil)
  }
}
