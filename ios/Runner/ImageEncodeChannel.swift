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
      out, type.identifier as CFString, 1, nil
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
