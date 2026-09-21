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
    // Answered before the image guard below, because it isn't about an
    // image: it says whether the face model loaded, and routing it
    // through "give me a readable photo first" made it answer "off" for
    // every call, model or no model.
    if call.method == "faceModel" {
      result(FaceEmbedder.shared.report())
      return
    }

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

    do {
      switch call.method {
      case "faces":
        result(try faces(VNImageRequestHandler(cgImage: cgImage, options: [:])))
      case "featurePrint":
        // Cropped before the request, not after: the descriptor is meant to
        // describe the face, and a whole-frame print of a beach portrait
        // mostly describes the beach.
        let region = cropped(cgImage, arguments) ?? cgImage
        // Aligned where the eyes can be found, plain where they can't —
        // and the two are kept in separate spaces rather than mixed.
        if let found = try? eyes(cgImage, arguments) {
          // A model trained on faces, where there is one. It wants its own
          // square — colour, 112 across, eyes on the template it was
          // trained against — so the alignment is done twice rather than
          // shared: the same picture prepared for two different questions.
          if FaceEmbedder.shared.isAvailable,
             let face = alignedFace(found.image, found.left, found.right),
             let embedding = FaceEmbedder.shared.embedding(face) {
            result(vector(embedding, pipeline: modelPipeline))
            return
          }
          if let aligned = alignedSquare(
            found.image,
            found.left,
            found.right
          ) {
            result(
              try featurePrint(
                VNImageRequestHandler(cgImage: aligned, options: [:]),
                pipeline: alignedPipeline
              )
            )
            return
          }
        }
        do {
          let square = normalised(region) ?? region
          result(
            try featurePrint(
              VNImageRequestHandler(cgImage: square, options: [:]),
              pipeline: pipeline
            )
          )
        }
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

  /// The sub-image a normalised, top-left-origin rect names. `nil` when the
  /// arguments carry no rect, which means "the whole image".
  private static func cropped(
    _ image: CGImage,
    _ arguments: [String: Any],
    grownBy margin: Double = 0
  ) -> CGImage? {
    guard let x = arguments["x"] as? Double,
          let y = arguments["y"] as? Double,
          let width = arguments["width"] as? Double,
          let height = arguments["height"] as? Double
    else { return nil }
    let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let rect = CGRect(
      x: (x - width * margin) * Double(image.width),
      y: (y - height * margin) * Double(image.height),
      width: width * (1 + margin * 2) * Double(image.width),
      height: height * (1 + margin * 2) * Double(image.height)
    ).integral.intersection(full)
    guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
    return image.cropping(to: rect)
  }

  /// The crop as a fixed-size grey square.
  ///
  /// The feature print describes an *image*, not a face, so whatever else
  /// varies between two crops lands in the answer. Two of those were
  /// ours to remove: colour, which made a warm living room match a warm
  /// living room rather than a person match a person; and size, which
  /// made a close-up and a face across a room different kinds of thing
  /// before they were different people. Both are noise here — a face is
  /// the same face in tungsten or daylight, near or far.
  private static func normalised(_ image: CGImage) -> CGImage? {
    let side = 224
    guard let context = CGContext(
      data: nil,
      width: side,
      height: side,
      bitsPerComponent: 8,
      bytesPerRow: side,
      space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return nil }
    context.interpolationQuality = .high
    context.draw(
      image,
      in: CGRect(x: 0, y: 0, width: side, height: side)
    )
    return context.makeImage()
  }

  /// Bumped whenever the preprocessing above changes. It travels with the
  /// vector because it defines the space just as much as Vision's own
  /// revision does: a print of a colour crop and a print of a grey square
  /// are not two answers to one question.
  ///
  /// `pipeline` is the unaligned square, `alignedPipeline` the same square
  /// with the eyes levelled and put in the same place every time. A face
  /// whose eyes Vision can't find still gets described — just in its own
  /// space, so an aligned print is never ranked against an unaligned one.
  private static let pipeline = 2
  private static let alignedPipeline = 3

  /// SFace. A different question answered by a different thing, so it
  /// gets its own space — a print of an image and an embedding of a face
  /// have nothing to say to each other.
  private static let modelPipeline = 4

  private static func vector(
    _ values: [Float],
    pipeline: Int
  ) -> [String: Any] {
    values.withUnsafeBufferPointer { buffer in
      [
        "revision": 1,
        "pipeline": pipeline,
        "elementCount": values.count,
        "vector": FlutterStandardTypedData(float32: Data(buffer: buffer)),
      ]
    }
  }

  /// The face warped onto SFace's own template: 112 across, in colour,
  /// with the eyes where the model was trained to find them.
  private static func alignedFace(
    _ image: CGImage,
    _ leftEye: CGPoint,
    _ rightEye: CGPoint
  ) -> CGImage? {
    let side = FaceEmbedder.side
    // Vision measures from the bottom up and CoreGraphics draws that way
    // too, but the template is written top-down — so the eye line is
    // mirrored into the context's own space.
    let left = CGPoint(
      x: FaceEmbedder.leftEyeTarget.x,
      y: Double(side) - FaceEmbedder.leftEyeTarget.y
    )
    let right = CGPoint(
      x: FaceEmbedder.rightEyeTarget.x,
      y: Double(side) - FaceEmbedder.rightEyeTarget.y
    )
    let dx = rightEye.x - leftEye.x
    let dy = rightEye.y - leftEye.y
    let spacing = (dx * dx + dy * dy).squareRoot()
    guard spacing > 1 else { return nil }
    let scale = (right.x - left.x) / spacing
    let angle = atan2(dy, dx)

    guard let context = CGContext(
      data: nil,
      width: side,
      height: side,
      bitsPerComponent: 8,
      bytesPerRow: side * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .high

    let sourceMid = CGPoint(
      x: (leftEye.x + rightEye.x) / 2,
      y: (leftEye.y + rightEye.y) / 2
    )
    context.translateBy(
      x: (left.x + right.x) / 2,
      y: (left.y + right.y) / 2
    )
    context.rotate(by: -angle)
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -sourceMid.x, y: -sourceMid.y)
    context.draw(
      image,
      in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
    )
    return context.makeImage()
  }

  /// The eyes, and the crop their coordinates belong to.
  ///
  /// Looked for in a generous crop around the face rather than the whole
  /// photo: landmarks over a full-resolution image is the slow path, and
  /// the face's own box is already known. The crop comes back with them
  /// because the points are in *its* pixels, not the photo's.
  private static func eyes(
    _ image: CGImage,
    _ arguments: [String: Any]
  ) throws -> (image: CGImage, left: CGPoint, right: CGPoint)? {
    guard let wide = cropped(image, arguments, grownBy: 0.6) else {
      return nil
    }
    let request = VNDetectFaceLandmarksRequest()
    try VNImageRequestHandler(cgImage: wide, options: [:]).perform([request])
    guard let face = request.results?.first,
          let left = face.landmarks?.leftEye,
          let right = face.landmarks?.rightEye
    else { return nil }
    let size = CGSize(width: wide.width, height: wide.height)
    return (wide, centre(left, size), centre(right, size))
  }

  private static func centre(
    _ region: VNFaceLandmarkRegion2D,
    _ size: CGSize
  ) -> CGPoint {
    let points = region.pointsInImage(imageSize: size)
    guard !points.isEmpty else { return .zero }
    let sum = points.reduce(CGPoint.zero) {
      CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
    }
    return CGPoint(
      x: sum.x / CGFloat(points.count),
      y: sum.y / CGFloat(points.count)
    )
  }

  /// The face drawn into a fixed grey square with the eyes levelled and
  /// always in the same two places.
  ///
  /// Two photos of one person differ most in how their head is turned and
  /// how big it is in frame. Neither is anything to do with who they are,
  /// and both are the bulk of what a general descriptor was answering
  /// about. This takes both out before the question is asked.
  private static func alignedSquare(
    _ image: CGImage,
    _ leftEye: CGPoint,
    _ rightEye: CGPoint
  ) -> CGImage? {
    let side = 224
    // Where the eyes go: level, a third in from each edge, a little above
    // centre — the arrangement face models are trained against.
    let targetLeft = CGPoint(x: 0.35 * Double(side), y: 0.62 * Double(side))
    let targetRight = CGPoint(x: 0.65 * Double(side), y: 0.62 * Double(side))

    let dx = rightEye.x - leftEye.x
    let dy = rightEye.y - leftEye.y
    let spacing = (dx * dx + dy * dy).squareRoot()
    guard spacing > 1 else { return nil }
    let scale = (targetRight.x - targetLeft.x) / spacing
    let angle = atan2(dy, dx)

    guard let context = CGContext(
      data: nil,
      width: side,
      height: side,
      bitsPerComponent: 8,
      bytesPerRow: side,
      space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return nil }
    context.interpolationQuality = .high

    let sourceMid = CGPoint(
      x: (leftEye.x + rightEye.x) / 2,
      y: (leftEye.y + rightEye.y) / 2
    )
    let targetMid = CGPoint(
      x: (targetLeft.x + targetRight.x) / 2,
      y: (targetLeft.y + targetRight.y) / 2
    )
    context.translateBy(x: targetMid.x, y: targetMid.y)
    context.rotate(by: -angle)
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -sourceMid.x, y: -sourceMid.y)
    context.draw(
      image,
      in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
    )
    return context.makeImage()
  }

  /// A descriptor of what the image looks like, for comparing one crop
  /// against another.
  ///
  /// Vision has no public face-*identity* model, so this is the general
  /// image feature print standing in for one: close enough to rank "is this
  /// the same person?" as a suggestion, nowhere near enough to assert it.
  ///
  /// The revision travels with the vector because prints are only
  /// comparable within one — a stored vector from an older iOS is not a
  /// worse answer, it is a different space.
  private static func featurePrint(
    _ handler: VNImageRequestHandler,
    pipeline: Int
  ) throws -> [String: Any] {
    let request = VNGenerateImageFeaturePrintRequest()
    try handler.perform([request])
    guard let print = request.results?.first as? VNFeaturePrintObservation
    else { return [:] }
    return [
      "revision": request.revision,
      "pipeline": pipeline,
      "elementCount": print.elementCount,
      "vector": FlutterStandardTypedData(float32: floats(print)),
    ]
  }

  /// Vision returns the print as raw bytes of whichever element type the
  /// revision uses; everything above this wants `Float32`.
  private static func floats(_ print: VNFeaturePrintObservation) -> Data {
    switch print.elementType {
    case .float:
      return print.data
    case .double:
      let doubles = print.data.withUnsafeBytes { raw in
        Array(raw.bindMemory(to: Float64.self))
      }
      return doubles.map { Float32($0) }.withUnsafeBufferPointer {
        Data(buffer: $0)
      }
    default:
      return Data()
    }
  }
}
