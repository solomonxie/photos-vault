import Flutter
import PDFKit
import UIKit

/// Text out of a PDF, over PDFKit.
///
/// PDFKit is part of iOS, so this costs nothing and downloads nothing — the
/// same argument that put face detection on Vision and AES on CommonCrypto.
/// The pure-Dart alternative is two to three megabytes against a budget with
/// half a megabyte spare, which is not a trade, it is a no.
///
/// Deliberately dumb: open the document, hand back its text. Whether that text
/// is worth sending anywhere lives in Dart, where it can be tested.
class DocumentTextChannel {
  static let name = "byo.photos/document"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: name,
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      // Parsing a long PDF is slow enough to drop frames, and the caller is
      // already showing a progress state.
      DispatchQueue.global(qos: .userInitiated).async {
        handle(call, result)
      }
    }
  }

  private static func handle(
    _ call: FlutterMethodCall,
    _ result: @escaping FlutterResult
  ) {
    switch call.method {
    case "pdfText":
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String
      else {
        result(nil)
        return
      }
      result(pdfText(path: path))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// `nil` for a file PDFKit will not open. An **empty string** is different
  /// and meaningful: a PDF that opens and has no text is a scan, and the
  /// caller says so rather than sending nothing to a vendor and being charged
  /// to hear it.
  private static func pdfText(path: String) -> String? {
    guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
      return nil
    }
    return document.string ?? ""
  }
}
