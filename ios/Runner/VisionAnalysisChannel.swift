import Flutter
import UIKit
import Vision

/// On-device photo analysis over Apple's Vision framework: scene labels,
/// face rectangles, and per-face descriptors for grouping.
///
/// Vision is the right engine for this app specifically because it costs
/// nothing and downloads nothing — the models are part of iOS. A library of
/// a hundred thousand photos is exactly the case where per-photo API
/// billing stops being viable, and the same size that makes a cloud call
/// expensive makes a local one free.
///
/// Everything here is deliberately dumb: decode, run a request, hand back
/// plain values. The decisions — which labels are worth keeping, how faces
/// are grouped into people — live in Dart where they can be tested.
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
      case "classify":
        result(try classify(handler, arguments))
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

  /// Scene/subject labels with their confidences, strongest first. The
  /// cut-off is applied in Dart: what counts as "confident enough" is a
  /// product decision, not a platform one.
  private static func classify(
    _ handler: VNImageRequestHandler,
    _ arguments: [String: Any]
  ) throws -> [[String: Any]] {
    let request = VNClassifyImageRequest()
    try handler.perform([request])
    let observations = request.results ?? []
    let limit = arguments["limit"] as? Int ?? 20
    return
      observations
      .sorted { $0.confidence > $1.confidence }
      .prefix(limit)
      .map { ["label": $0.identifier, "confidence": Double($0.confidence)] }
  }

  /// Face rectangles in Vision's normalised, bottom-left-origin space,
  /// plus a per-face descriptor.
  ///
  /// The descriptor is a feature print of the face crop. Vision has no
  /// public face-identity API — that's Photos' own private model — so
  /// grouping is done in Dart by comparing these. It's a weaker signal than
  /// a purpose-built face embedding, which is why the clustering threshold
  /// is tuned conservatively: two photos wrongly called the same person is
  /// a worse failure than two clusters of one person.
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
