import Flutter
import ImageIO
import UIKit

/// Square face thumbnails cut from a photo file.
/// The boxes come from the Mac's face import; the phone finds no faces
/// itself.
///
/// Deliberately dumb: decode, cut, hand back bytes. Which faces to cut
/// lives in Dart, where it can be tested.
class FaceCropChannel {
  static let name = "byo.photos/vision"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: name,
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      // Decoding is slow enough to matter; off the platform thread.
      DispatchQueue.global(qos: .utility).async {
        handle(call, result)
      }
    }
  }

  private static func handle(
    _ call: FlutterMethodCall,
    _ result: @escaping FlutterResult
  ) {
    guard let arguments = call.arguments as? [String: Any] else {
      result(unreadable())
      return
    }
    let path = arguments["path"] as? String ?? ""

    guard call.method == "crops" else {
      result(FlutterMethodNotImplemented)
      return
    }
    // One decode per call, upright and capped (05#7, #14): crops live in
    // the picture as it is shown.
    guard let cgImage = upright(path) else {
      result(unreadable())
      return
    }
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
  }

  private static func unreadable() -> FlutterError {
    FlutterError(
      code: "unreadable",
      message: "No image at the given path",
      details: nil
    )
  }

  /// Longest side the crops work from: plenty for a 160 px thumbnail,
  /// where a 48 MP decode isn't.
  private static let maxSide = 2048

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
}
