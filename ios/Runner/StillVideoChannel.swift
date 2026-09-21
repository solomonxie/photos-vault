import AVFoundation
import Flutter
import UIKit

/// Builds the decoy half of a video carrier: one frame, held for a real
/// duration.
///
/// The duration is the whole point. A two-second clip weighing 200 MB is
/// absurd and a script can spot it across an entire bucket without watching
/// anything; the same bytes over three minutes are an ordinary 9 Mbps
/// capture. So the caller passes the duration and resolution of a real
/// video of about the payload's size, and this holds a single still for
/// exactly that long.
///
/// Cheap because identical frames encode to almost nothing — one keyframe
/// plus a few hundred bytes a frame, in hardware, seconds rather than the
/// minutes a full-length re-encode of somebody's real video would cost.
class StillVideoChannel {
  static let name = "byo.photos/still_video"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: name,
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      DispatchQueue.global(qos: .utility).async {
        handle(call, result)
      }
    }
  }

  private static func handle(
    _ call: FlutterMethodCall,
    _ result: @escaping FlutterResult
  ) {
    switch call.method {
    case "render":
      guard let arguments = call.arguments as? [String: Any],
            let still = arguments["still"] as? FlutterStandardTypedData,
            let width = arguments["width"] as? Int,
            let height = arguments["height"] as? Int,
            let seconds = arguments["seconds"] as? Double,
            let path = arguments["path"] as? String
      else {
        result(nil)
        return
      }
      let fps = (arguments["fps"] as? Int) ?? 30
      result(
        render(
          still: still.data,
          width: width,
          height: height,
          seconds: seconds,
          fps: fps,
          path: path
        ) ? path : nil
      )
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func render(
    still: Data,
    width: Int,
    height: Int,
    seconds: Double,
    fps: Int,
    path: String
  ) -> Bool {
    guard let image = UIImage(data: still)?.cgImage, seconds > 0 else {
      return false
    }
    // Even dimensions, or the encoder refuses.
    let outWidth = max(2, width - (width % 2))
    let outHeight = max(2, height - (height % 2))
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)

    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov)
    else { return false }

    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: outWidth,
      AVVideoHeightKey: outHeight,
      AVVideoCompressionPropertiesKey: [
        // One keyframe for the whole clip. Periodic ones would cost more
        // than the entire rest of the file, every frame being identical.
        AVVideoMaxKeyFrameIntervalKey: Int(seconds * Double(fps)) + 1,
        AVVideoAverageBitRateKey: 600_000,
      ],
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String:
          kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: outWidth,
        kCVPixelBufferHeightKey as String: outHeight,
      ]
    )
    guard writer.canAdd(input) else { return false }
    writer.add(input)
    guard writer.startWriting() else { return false }
    writer.startSession(atSourceTime: .zero)

    guard let buffer = pixelBuffer(
      from: image,
      width: outWidth,
      height: outHeight
    ) else {
      writer.cancelWriting()
      return false
    }

    let total = max(1, Int(seconds * Double(fps)))
    var frame = 0
    let queue = DispatchQueue(label: "byo.photos.still-video")
    let done = DispatchSemaphore(value: 0)
    input.requestMediaDataWhenReady(on: queue) {
      while input.isReadyForMoreMediaData {
        if frame >= total {
          input.markAsFinished()
          writer.finishWriting { done.signal() }
          return
        }
        adaptor.append(
          buffer,
          withPresentationTime: CMTime(
            value: CMTimeValue(frame),
            timescale: CMTimeScale(fps)
          )
        )
        frame += 1
      }
    }
    done.wait()
    return writer.status == .completed
  }

  private static func pixelBuffer(
    from image: CGImage,
    width: Int,
    height: Int
  ) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attributes: [String: Any] = [
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ]
    guard CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      attributes as CFDictionary,
      &buffer
    ) == kCVReturnSuccess, let pixels = buffer else { return nil }

    CVPixelBufferLockBaseAddress(pixels, [])
    defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
    guard let context = CGContext(
      data: CVPixelBufferGetBaseAddress(pixels),
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }
    context.draw(
      image,
      in: CGRect(x: 0, y: 0, width: width, height: height)
    )
    return pixels
  }
}
