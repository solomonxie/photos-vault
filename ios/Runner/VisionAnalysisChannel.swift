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

    // One decode per call, upright and capped (05#7, #14): boxes and crops
    // live in the picture as it is shown.
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
