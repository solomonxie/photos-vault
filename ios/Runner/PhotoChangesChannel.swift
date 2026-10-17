import Flutter
import Foundation
import Photos

/// PhotoKit's persistent change history (iOS 16+): which assets were
/// inserted, updated or deleted since a token, so a resume reads what
/// changed rather than the whole camera roll.
///
/// Tokens cross the channel as base64 of the archived
/// `PHPersistentChangeToken`. Anything that can't be answered — iOS 15, an
/// expired token, history PhotoKit no longer has — is nil, and Dart falls
/// back to a full pass.
class PhotoChangesChannel {
  static let name = "byo.photos/photo_changes"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: name,
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      handle(call, result)
    }
  }

  private static func handle(
    _ call: FlutterMethodCall,
    _ result: @escaping FlutterResult
  ) {
    guard #available(iOS 16, *) else {
      result(nil)
      return
    }
    switch call.method {
    case "token":
      DispatchQueue.global(qos: .utility).async {
        let token = encode(PHPhotoLibrary.shared().currentChangeToken)
        DispatchQueue.main.async { result(token) }
      }
    case "since":
      guard let text = call.arguments as? String,
            let token = decode(text)
      else {
        result(nil)
        return
      }
      DispatchQueue.global(qos: .utility).async {
        let changes = since(token)
        DispatchQueue.main.async { result(changes) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  @available(iOS 16, *)
  private static func since(_ token: PHPersistentChangeToken) -> [String: Any]? {
    let library = PHPhotoLibrary.shared()
    // Taken before the read: a change landing during it is replayed next
    // time rather than skipped.
    guard let next = encode(library.currentChangeToken) else { return nil }
    let changes: PHPersistentChangeFetchResult
    do {
      changes = try library.fetchPersistentChanges(since: token)
    } catch {
      return nil
    }
    var inserted = Set<String>()
    var updated = Set<String>()
    var deleted = Set<String>()
    var complete = true
    changes.enumerateChanges { change, stop in
      do {
        let details = try change.changeDetails(for: .asset)
        inserted.formUnion(details.insertedLocalIdentifiers)
        updated.formUnion(details.updatedLocalIdentifiers)
        deleted.formUnion(details.deletedLocalIdentifiers)
      } catch {
        complete = false
        stop.pointee = true
      }
    }
    guard complete else { return nil }
    return [
      "inserted": Array(inserted),
      "updated": Array(updated),
      "deleted": Array(deleted),
      "token": next,
    ]
  }

  @available(iOS 16, *)
  private static func encode(_ token: PHPersistentChangeToken) -> String? {
    try? NSKeyedArchiver.archivedData(
      withRootObject: token,
      requiringSecureCoding: true
    ).base64EncodedString()
  }

  @available(iOS 16, *)
  private static func decode(_ text: String) -> PHPersistentChangeToken? {
    guard let data = Data(base64Encoded: text) else { return nil }
    return try? NSKeyedUnarchiver.unarchivedObject(
      ofClass: PHPersistentChangeToken.self,
      from: data
    )
  }
}
