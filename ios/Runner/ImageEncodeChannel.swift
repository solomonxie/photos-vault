import AVFoundation
import Flutter
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Re-encodes a photo with ImageIO: reads anything iOS reads (HEIC
/// included), downsamples during the decode, writes HEIC or JPEG with the
/// hardware encoder. HEIC is about half a JPEG at the same quality, and
/// encoding it this way costs the app nothing in size.
///
/// EXIF and GPS ride along; orientation is baked into the pixels, so it is
/// reset to up.
class ImageEncodeChannel {
  static let name = "byo.photos/image_encode"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: name,
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      if call.method == "encodeFile" {
        encodeFile(call, result)
        return
      }
      if call.method == "compressVideo" {
        compressVideo(call, result)
        return
      }
      if call.method == "edit" {
        edit(call, result)
        return
      }
      if call.method == "remoteThumbnail" {
        remoteThumbnail(call, result)
        return
      }
      guard call.method == "encode",
            let args = call.arguments as? [String: Any],
            let data = args["bytes"] as? FlutterStandardTypedData,
            let format = args["format"] as? String
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      let maxEdge = args["maxEdge"] as? Int
      let quality = args["quality"] as? Double ?? 0.8
      DispatchQueue.global(qos: .userInitiated).async {
        let out = encode(
          data.data,
          type: format == "heic" ? UTType.heic : UTType.jpeg,
          maxEdge: maxEdge,
          quality: quality
        )
        DispatchQueue.main.async {
          result(out.map { FlutterStandardTypedData(bytes: $0) })
        }
      }
    }
  }

  /// File to file, so a full-size photo never crosses the channel. True
  /// when [output] was written; with `onlyIfSmaller`, only when it came out
  /// smaller than the input.
  private static func encodeFile(
    _ call: FlutterMethodCall,
    _ result: @escaping FlutterResult
  ) {
    guard let args = call.arguments as? [String: Any],
          let input = args["input"] as? String,
          let output = args["output"] as? String,
          let format = args["format"] as? String
    else {
      result(false)
      return
    }
    let onlyIfSmaller = args["onlyIfSmaller"] as? Bool ?? true
    let quality = args["quality"] as? Double ?? 0.8
    DispatchQueue.global(qos: .utility).async {
      var wrote = false
      if let data = FileManager.default.contents(atPath: input),
         let out = encode(
           data,
           type: format == "heic" ? UTType.heic : UTType.jpeg,
           maxEdge: args["maxEdge"] as? Int,
           quality: quality
         ),
         !onlyIfSmaller || out.count < data.count {
        wrote = FileManager.default.createFile(atPath: output, contents: out)
      }
      DispatchQueue.main.async { result(wrote) }
    }
  }

  /// A thumbnail written to [output] without the whole file: a video's
  /// frame read by AVFoundation straight from [url] (it range-requests only
  /// what the frame needs), or a photo's from the first [bytes] of it —
  /// its embedded preview, else whatever of it decodes. True when written.
  private static func remoteThumbnail(
    _ call: FlutterMethodCall,
    _ result: @escaping FlutterResult
  ) {
    guard let args = call.arguments as? [String: Any],
          let output = args["output"] as? String
    else {
      result(false)
      return
    }
    let maxEdge = args["maxEdge"] as? Int ?? 640
    let write = { (image: CGImage?) in
      var wrote = false
      let data = NSMutableData()
      if let image = image,
         let dest = CGImageDestinationCreateWithData(
           data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
         ) {
        CGImageDestinationAddImage(
          dest, image,
          [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        )
        if CGImageDestinationFinalize(dest) {
          wrote = FileManager.default.createFile(
            atPath: output, contents: data as Data
          )
        }
      }
      DispatchQueue.main.async { result(wrote) }
    }
    if let bytes = args["bytes"] as? FlutterStandardTypedData {
      DispatchQueue.global(qos: .utility).async {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, bytes.data as CFData, false)
        write(CGImageSourceCreateThumbnailAtIndex(source, 0, [
          kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ] as CFDictionary))
      }
      return
    }
    guard let raw = args["url"] as? String, let url = URL(string: raw) else {
      result(false)
      return
    }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxEdge, height: maxEdge)
    generator.requestedTimeToleranceBefore = .positiveInfinity
    generator.requestedTimeToleranceAfter = .positiveInfinity
    let at = CMTime(seconds: 1, preferredTimescale: 600)
    if #available(iOS 16, *) {
      generator.generateCGImageAsynchronously(for: at) { image, _, _ in
        write(image)
      }
    } else {
      DispatchQueue.global(qos: .utility).async {
        write(try? generator.copyCGImage(at: at, actualTime: nil))
      }
    }
  }

  /// A video re-encoded to 1080p HEVC by AVFoundation, metadata (date,
  /// place) carried over. True only when [output] came out smaller.
  private static func compressVideo(
    _ call: FlutterMethodCall,
    _ result: @escaping FlutterResult
  ) {
    guard let args = call.arguments as? [String: Any],
          let input = args["input"] as? String,
          let output = args["output"] as? String
    else {
      result(false)
      return
    }
    let asset = AVURLAsset(url: URL(fileURLWithPath: input))
    guard let session = AVAssetExportSession(
      asset: asset,
      presetName: AVAssetExportPresetHEVC1920x1080
    ) else {
      result("no HEVC export for this video")
      return
    }
    let out = URL(fileURLWithPath: output)
    try? FileManager.default.removeItem(at: out)
    session.outputURL = out
    session.outputFileType = .mov
    session.metadata = asset.metadata
    // True, or why not, so a failure can say what went wrong.
    session.exportAsynchronously {
      var answer: Any = true
      if session.status != .completed {
        answer = session.error?.localizedDescription
          ?? "export ended: \(session.status.rawValue)"
      } else {
        let size = { (path: String) -> Int in
          ((try? FileManager.default.attributesOfItem(atPath: path))?[.size]
            as? NSNumber)?.intValue ?? 0
        }
        let written = size(output)
        if written == 0 || written >= size(input) {
          answer = "not smaller (\(written) of \(size(input)) bytes)"
          try? FileManager.default.removeItem(at: out)
        }
      }
      DispatchQueue.main.async { result(answer) }
    }
  }

  /// Crop (0..1 fractions of the upright image, `[l, t, r, b]`) and/or
  /// rotate (degrees clockwise) at full size, written back in the source's
  /// own format. Null when ImageIO can't write that format.
  private static func edit(
    _ call: FlutterMethodCall,
    _ result: @escaping FlutterResult
  ) {
    guard let args = call.arguments as? [String: Any],
          let data = args["bytes"] as? FlutterStandardTypedData
    else {
      result(nil)
      return
    }
    let crop = args["crop"] as? [Double]
    let degrees = args["degrees"] as? Double ?? 0
    let quality = args["quality"] as? Double ?? 0.92
    DispatchQueue.global(qos: .userInitiated).async {
      let out = edited(data.data, crop: crop, degrees: degrees, quality: quality)
      DispatchQueue.main.async {
        result(out.map { FlutterStandardTypedData(bytes: $0) })
      }
    }
  }

  private static func edited(
    _ data: Data,
    crop: [Double]?,
    degrees: Double,
    quality: Double
  ) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let type = CGImageSourceGetType(source),
          let writable = CGImageDestinationCopyTypeIdentifiers() as? [String],
          writable.contains(type as String),
          let size = pixelSize(source),
          var image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
          ] as CFDictionary)
    else { return nil }
    if let c = crop, c.count == 4 {
      let w = Double(image.width), h = Double(image.height)
      let rect = CGRect(
        x: c[0] * w, y: c[1] * h,
        width: (c[2] - c[0]) * w, height: (c[3] - c[1]) * h
      ).integral
      guard let cropped = image.cropping(to: rect) else { return nil }
      image = cropped
    }
    if degrees.truncatingRemainder(dividingBy: 360) != 0 {
      guard let rotated = rotate(image, degrees: degrees) else { return nil }
      image = rotated
    }
    return write(image, from: source, type: type as String, quality: quality)
  }

  /// On a canvas grown to fit the turned image; the corners are left empty.
  private static func rotate(_ image: CGImage, degrees: Double) -> CGImage? {
    let radians = CGFloat(degrees * .pi / 180)
    let w = CGFloat(image.width), h = CGFloat(image.height)
    let bounds = CGRect(x: 0, y: 0, width: w, height: h)
      .applying(CGAffineTransform(rotationAngle: radians)).integral
    let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
      ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
      data: nil,
      width: Int(bounds.width),
      height: Int(bounds.height),
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.translateBy(x: bounds.width / 2, y: bounds.height / 2)
    // CoreGraphics is y-up, so clockwise on screen is a negative angle.
    context.rotate(by: -radians)
    context.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
    return context.makeImage()
  }

  private static func encode(
    _ data: Data,
    type: UTType,
    maxEdge: Int?,
    quality: Double
  ) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let size = pixelSize(source)
    else { return nil }
    let longest = max(size.width, size.height)
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: min(maxEdge ?? longest, longest),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(
      source, 0, options as CFDictionary
    ) else { return nil }
    return write(image, from: source, type: type.identifier, quality: quality)
  }

  /// [image] with [source]'s EXIF and GPS, orientation reset to up.
  private static func write(
    _ image: CGImage,
    from source: CGImageSource,
    type: String,
    quality: Double
  ) -> Data? {
    var properties =
      (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
      ?? [:]
    properties[kCGImagePropertyOrientation] = 1
    properties[kCGImagePropertyPixelWidth] = nil
    properties[kCGImagePropertyPixelHeight] = nil
    if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
      tiff[kCGImagePropertyTIFFOrientation] = 1
      properties[kCGImagePropertyTIFFDictionary] = tiff
    }
    properties[kCGImageDestinationLossyCompressionQuality] = quality

    let out = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      out, type as CFString, 1, nil
    ) else { return nil }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return out as Data
  }

  private static func pixelSize(_ source: CGImageSource) -> (width: Int, height: Int)? {
    guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (w, h)
  }
}
