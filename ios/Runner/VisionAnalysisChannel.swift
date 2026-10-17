import Flutter
import ImageIO
import Photos
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

    // A file, or a camera-roll asset by its PhotoKit id (BG-10): rendered
    // here at the size Vision uses, so no full-size JPEG goes through tmp.
    guard let arguments = call.arguments as? [String: Any] else {
      result(unreadable())
      return
    }
    let asset = arguments["asset"] as? String
    let path = arguments["path"] as? String ?? ""

    // Header only: the EXIF orientation, for boxes measured before they
    // were measured upright. A file's question; an asset has no header.
    if call.method == "orientation" {
      result(asset == nil ? orientation(path) : unreadable())
      return
    }

    // One decode per call, upright and capped (05#7, #14): boxes, crops
    // and descriptors all live in the picture as it is shown.
    let image: CGImage?
    if let asset {
      image = rendered(asset)
    } else {
      image = upright(path)
    }
    guard let cgImage = image else {
      result(unreadable())
      return
    }

    do {
      switch call.method {
      case "faces":
        result(try faces(VNImageRequestHandler(cgImage: cgImage, options: [:])))
      case "facesWithPrints":
        // Detect and describe from the one picture: a photo's faces and
        // their descriptors in a single render (BG-10). Only faces Dart
        // would keep are described.
        let minArea = arguments["minArea"] as? Double ?? 0
        let padding = arguments["padding"] as? Double ?? 0.08
        let found = try faces(
          VNImageRequestHandler(cgImage: cgImage, options: [:])
        )
        result(found.map { face -> [String: Any] in
          let width = face["width"] as? Double ?? 0
          let height = face["height"] as? Double ?? 0
          guard width * height >= minArea else { return face }
          var out = face
          out["print"] = (try? describe(
            cgImage,
            rectArguments(descriptorRect(face, padding: padding))
          )) ?? [:]
          return out
        })
      case "featurePrint":
        result(try describe(cgImage, arguments))
      case "featurePrints":
        let rects = arguments["faces"] as? [[Double]] ?? []
        result(rects.map { rect -> [String: Any] in
          (try? describe(cgImage, rectArguments(rect))) ?? [:]
        })
      case "crops":
        let rects = arguments["faces"] as? [[Double]] ?? []
        let padding = arguments["padding"] as? Double ?? 0.45
        let side = arguments["side"] as? Int ?? 160
        var out: [FlutterStandardTypedData] = []
        for rect in rects {
          guard rect.count == 4,
                let data = crop(cgImage, rect, padding: padding, side: side)
          else {
            result(unreadable())
            return
          }
          out.append(FlutterStandardTypedData(bytes: data))
        }
        result(out)
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

  private static func unreadable() -> FlutterError {
    FlutterError(
      code: "unreadable",
      message: "No image at the given path",
      details: nil
    )
  }

  private static func rectArguments(_ rect: [Double]) -> [String: Any] {
    guard rect.count == 4 else { return [:] }
    return ["x": rect[0], "y": rect[1], "width": rect[2], "height": rect[3]]
  }

  /// Longest side Vision and the crops work from. Faces small enough to
  /// count stay over a hundred pixels across; a 48 MP decode doesn't.
  private static let maxSide = 2048

  /// The asset as Photos shows it — edits applied, upright, at most
  /// [maxSide] — straight from PhotoKit, with no file in between.
  /// Synchronous, which is allowed here: this runs on the utility queue,
  /// never the main thread. iCloud originals may download, as `.file`
  /// let them.
  private static func rendered(_ localIdentifier: String) -> CGImage? {
    guard let asset = PHAsset.fetchAssets(
      withLocalIdentifiers: [localIdentifier],
      options: nil
    ).firstObject, asset.mediaType == .image else { return nil }
    let options = PHImageRequestOptions()
    options.isSynchronous = true
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .exact
    options.isNetworkAccessAllowed = true
    options.version = .current
    var image: UIImage?
    PHImageManager.default().requestImage(
      for: asset,
      targetSize: CGSize(width: maxSide, height: maxSide),
      contentMode: .aspectFit,
      options: options
    ) { result, _ in
      image = result
    }
    return image.flatMap(drawnUpright)
  }

  /// [image]'s pixels the right way up. PhotoKit can hand back a picture
  /// whose orientation is only a flag; every box here is measured upright.
  private static func drawnUpright(_ image: UIImage) -> CGImage? {
    if image.imageOrientation == .up, let cgImage = image.cgImage {
      return cgImage
    }
    let size = CGSize(
      width: image.size.width * image.scale,
      height: image.size.height * image.scale
    )
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.preferredRange = .standard
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }.cgImage
  }

  /// `FaceCrops.descriptorRect` for a Vision box: top-left, grown by
  /// [padding], squared and kept inside the frame. Must match the Dart.
  private static func descriptorRect(
    _ face: [String: Any],
    padding: Double
  ) -> [Double] {
    let x = face["x"] as? Double ?? 0
    let width = face["width"] as? Double ?? 0
    let height = face["height"] as? Double ?? 0
    let top = 1 - (face["y"] as? Double ?? 0) - height
    let box = min(max(width, height) * (1 + padding * 2), 1)
    let centreX = x + width / 2
    let centreY = top + height / 2
    return [
      min(max(centreX - box / 2, 0), 1 - box),
      min(max(centreY - box / 2, 0), 1 - box),
      box,
      box,
    ]
  }

  /// The picture as shown: EXIF orientation applied, at most [maxSide].
  private static func upright(_ path: String) -> CGImage? {
    guard !path.isEmpty,
          let source = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: path) as CFURL,
            nil
          )
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxSide,
    ]
    return CGImageSourceCreateThumbnailAtIndex(
      source,
      0,
      options as CFDictionary
    )
  }

  private static func orientation(_ path: String) -> Int {
    guard let source = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: path) as CFURL,
            nil
          ),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
    else { return 1 }
    return (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
      ?? 1
  }

  /// A square JPEG of one face, padded and slid inside the frame — the
  /// same cut `FaceCrops` makes in Dart, minus the Dart decode (05#15).
  private static func crop(
    _ image: CGImage,
    _ rect: [Double],
    padding: Double,
    side: Int
  ) -> Data? {
    let w = Double(image.width)
    let h = Double(image.height)
    let padded = max(rect[2] * w, rect[3] * h) * (1 + padding * 2)
    let box = min(max(padded.rounded(), 1), min(w, h))
    let centreX = (rect[0] + rect[2] / 2) * w
    let centreY = (rect[1] + rect[3] / 2) * h
    let left = min(max((centreX - box / 2).rounded(), 0), w - box)
    let top = min(max((centreY - box / 2).rounded(), 0), h - box)
    guard let cut = image.cropping(
      to: CGRect(x: left, y: top, width: box, height: box)
    ),
    let context = CGContext(
      data: nil,
      width: side,
      height: side,
      bitsPerComponent: 8,
      bytesPerRow: side * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .high
    context.draw(cut, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let scaled = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data as CFMutableData,
      "public.jpeg" as CFString,
      1,
      nil
    ) else { return nil }
    CGImageDestinationAddImage(
      destination,
      scaled,
      [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }

  /// One face's descriptor. Cropped before the request, not after: the
  /// descriptor is meant to describe the face, and a whole-frame print of
  /// a beach portrait mostly describes the beach.
  private static func describe(
    _ cgImage: CGImage,
    _ arguments: [String: Any]
  ) throws -> [String: Any] {
    let region = cropped(cgImage, arguments) ?? cgImage
    // Aligned where the eyes can be found, plain where they can't — and
    // the two are kept in separate spaces rather than mixed.
    if let found = try? eyes(cgImage, arguments) {
      if FaceEmbedder.shared.isAvailable {
        // A model trained on faces. It wants its own square — colour, 112
        // across, eyes on its template. If it refuses this face, the plain
        // print below, never the superseded aligned one: that space is
        // only live while the model is missing (05#5).
        if let face = alignedFace(found.image, found.left, found.right),
           let embedding = FaceEmbedder.shared.embedding(face) {
          return vector(embedding, pipeline: modelPipeline)
        }
      } else if let aligned = alignedSquare(
        found.image,
        found.left,
        found.right
      ) {
        return try featurePrint(
          VNImageRequestHandler(cgImage: aligned, options: [:]),
          pipeline: alignedPipeline
        )
      }
    }
    let square = normalised(region) ?? region
    return try featurePrint(
      VNImageRequestHandler(cgImage: square, options: [:]),
      pipeline: pipeline
    )
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
