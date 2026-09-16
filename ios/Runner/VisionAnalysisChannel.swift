import Flutter
import UIKit
import Vision

/// Face detection over Apple's Vision framework.
///
/// Vision costs nothing and downloads nothing — the models are part of iOS
/// — which is what makes this viable over a library where per-photo API
/// billing isn't. It also classifies scenes, and that half was tried and
/// dropped: the labels were confident, plausible and wrong often enough
/// that every tag had to be checked, which is more work than typing the
/// right one. Tagging went back to the vendor models; faces stayed here,
/// where detection is genuinely reliable.
///
/// Deliberately dumb: decode, run a request, hand back plain values. What
/// counts as a face worth showing lives in Dart, where it can be tested.
class VisionAnalysisChannel {
  static let name = "byo.photos/vision"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: name,
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      // Vision is synchronous and slow enough to matter; keeping it off the
      // platform thread is what stops a library-wide analysis run freezing
      // the UI between frames.
      DispatchQueue.global(qos: .utility).async {
        handle(call, result)
      }
    }
  }

  private static func handle(
    _ call: FlutterMethodCall,
    _ result: @escaping FlutterResult
  ) {
    guard let arguments = call.arguments as? [String: Any],
          let path = arguments["path"] as? String,
          let image = UIImage(contentsOfFile: path),
          let cgImage = image.cgImage
    else {
      result(
        FlutterError(
          code: "unreadable",
          message: "No image at the given path",
          details: nil
        )
      )
      return
    }

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
      switch call.method {
      case "faces":
        result(try faces(handler))
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      result(
        FlutterError(
          code: "vision-failed",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  /// Face rectangles in Vision's normalised, bottom-left-origin space.
  ///
  /// Rectangles only: Vision has no public face-*identity* API — that's
  /// Photos' own private model — so the app shows the faces it found and
  /// lets the user say who they are.
  private static func faces(_ handler: VNImageRequestHandler) throws
    -> [[String: Any]]
  {
    let request = VNDetectFaceRectanglesRequest()
    try handler.perform([request])
    return (request.results ?? []).map { observation in
      let box = observation.boundingBox
      return [
        "x": Double(box.origin.x),
        "y": Double(box.origin.y),
        "width": Double(box.size.width),
        "height": Double(box.size.height),
      ]
    }
  }
}
