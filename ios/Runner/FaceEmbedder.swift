import CoreML
import CoreGraphics
import Foundation

/// SFace, run on the phone: a face in, 128 numbers out, close together for
/// two photos of one person and far apart for two people.
///
/// This is what Vision's own feature print was standing in for. That one
/// describes an *image* — it was answering "were these taken in the same
/// room?" about as much as "are these the same person?". This one was
/// trained on faces and nothing else.
///
/// OpenCV Zoo's SFace, Apache-2.0, converted and quantised to int8 by
/// `scripts/convert_sface.py`. 9.3 MB in the bundle, which is the whole
/// reason it isn't larger and more accurate still.
final class FaceEmbedder {
  static let shared = FaceEmbedder()

  /// What SFace was trained against: 112x112, BGR, raw 0-255, and the face
  /// warped so the eyes sit on the same two pixels every time.
  static let side = 112

  /// The eyes' place in that square — the ArcFace template SFace and every
  /// model of its family align to. Getting this wrong doesn't fail, it
  /// just quietly answers worse, which is the hard kind of wrong.
  static let leftEyeTarget = CGPoint(x: 38.2946, y: 51.6963)
  static let rightEyeTarget = CGPoint(x: 73.5318, y: 51.5014)

  /// Why it isn't loaded, when it isn't. Kept because "off" on its own
  /// sent us looking in the wrong place once already.
  private(set) var failure: String?

  private lazy var model: MLModel? = {
    guard let url = Bundle.main.url(
      forResource: "SFace",
      withExtension: "mlmodelc"
    ) else {
      failure = "SFace.mlmodelc not in the bundle"
      return nil
    }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .all
    do {
      return try MLModel(contentsOf: url, configuration: configuration)
    } catch {
      failure = "\(error)"
      return nil
    }
  }()

  var isAvailable: Bool { model != nil }

  /// `true`, or the reason it isn't — so a failure says what went wrong
  /// instead of only that something did.
  func report() -> Any {
    isAvailable ? true : (failure ?? "not loaded")
  }

  /// The embedding for an already-aligned 112x112 BGR image, or `nil` when
  /// the model isn't there or refuses it — in which case the caller falls
  /// back to the feature print, which is worse but is an answer.
  func embedding(_ image: CGImage) -> [Float]? {
    guard let model else { return nil }
    guard let input = try? MLMultiArray(
      shape: [1, 3, NSNumber(value: Self.side), NSNumber(value: Self.side)],
      dataType: .float32
    ) else { return nil }
    guard let pixels = bgrPlanes(image) else { return nil }
    let pointer = input.dataPointer.bindMemory(
      to: Float32.self,
      capacity: pixels.count
    )
    pointer.update(from: pixels, count: pixels.count)

    guard let provider = try? MLDictionaryFeatureProvider(
      dictionary: ["data": MLFeatureValue(multiArray: input)]
    ) else { return nil }
    guard let out = try? model.prediction(from: provider),
          let name = out.featureNames.first,
          let array = out.featureValue(for: name)?.multiArrayValue
    else { return nil }

    let values = array.dataPointer.bindMemory(
      to: Float32.self,
      capacity: array.count
    )
    return Array(UnsafeBufferPointer(start: values, count: array.count))
  }

  /// Planar BGR floats, 0-255 — the layout `blobFromImage` produces, which
  /// is what this model was exported expecting.
  private func bgrPlanes(_ image: CGImage) -> [Float32]? {
    let side = Self.side
    let count = side * side
    var rgba = [UInt8](repeating: 0, count: count * 4)
    guard let context = CGContext(
      data: &rgba,
      width: side,
      height: side,
      bitsPerComponent: 8,
      bytesPerRow: side * 4,
      space: CGColorSpaceDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(
      image,
      in: CGRect(x: 0, y: 0, width: side, height: side)
    )
    var planes = [Float32](repeating: 0, count: count * 3)
    for i in 0..<count {
      planes[i] = Float32(rgba[i * 4 + 2])              // B
      planes[count + i] = Float32(rgba[i * 4 + 1])      // G
      planes[count * 2 + i] = Float32(rgba[i * 4])      // R
    }
    return planes
  }

  private func CGColorSpaceDeviceRGB() -> CGColorSpace {
    CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
  }
}
