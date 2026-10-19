import UIKit
import UniformTypeIdentifiers

/// "Photos Vault" in the share sheet. Copies the shared images and videos
/// into the App Group's inbox and closes; the app files them on its next
/// open (`lib/photos/share_inbox.dart`). Nothing here touches Photos.
///
/// The inbox is plain files, out of the device backup, until the app takes
/// them. Kept to copying: the hide path is Dart, and an extension gets
/// ~120 MB of memory, so nothing is decoded here.
class ShareViewController: UIViewController {
  private let status = UILabel()
  private let spinner = UIActivityIndicatorView(style: .large)

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    status.text = NSLocalizedString("Saving…", comment: "")
    status.textAlignment = .center
    status.numberOfLines = 0
    status.font = .preferredFont(forTextStyle: .headline)
    let stack = UIStackView(arrangedSubviews: [spinner, status])
    stack.axis = .vertical
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
    ])
    spinner.startAnimating()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    Task { await save() }
  }

  private func save() async {
    let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
      .flatMap { $0.attachments ?? [] }
    var saved = 0
    if let inbox = ShareInbox.directory() {
      for provider in providers {
        if await ShareInbox.copy(provider, into: inbox) { saved += 1 }
      }
    }
    spinner.stopAnimating()
    status.text = saved == 0
      ? NSLocalizedString("Couldn't save this.", comment: "")
      : String.localizedStringWithFormat(
        NSLocalizedString("Saved %d. Open Photos Vault to put them away.", comment: ""),
        saved
      )
    try? await Task.sleep(nanoseconds: 1_200_000_000)
    extensionContext?.completeRequest(returningItems: nil)
  }
}

enum ShareInbox {
  static func directory() -> URL? {
    guard let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as? String,
          let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: group
          )
    else { return nil }
    var dir = root.appendingPathComponent("ShareInbox", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? dir.setResourceValues(values)
    return dir
  }

  /// The provider's own file where it has one (keeps HEIC, EXIF, GIF frames);
  /// a re-encoded JPEG only for apps that hand over a bare image.
  static func copy(_ provider: NSItemProvider, into inbox: URL) async -> Bool {
    let wanted = provider.registeredTypeIdentifiers.compactMap(UTType.init)
      .first { $0.conforms(to: .image) || $0.conforms(to: .movie) }
    guard let type = wanted else { return false }
    let name = UUID().uuidString
    if let url = await fileURL(provider, type) {
      defer { try? FileManager.default.removeItem(at: url) }
      let ext = url.pathExtension.isEmpty
        ? (type.preferredFilenameExtension ?? "jpg")
        : url.pathExtension
      // `.part` then rename, so the app never takes a half-written file.
      let part = inbox.appendingPathComponent("\(name).part")
      let final = inbox.appendingPathComponent("\(name).\(ext.lowercased())")
      do {
        try FileManager.default.copyItem(at: url, to: part)
        try FileManager.default.moveItem(at: part, to: final)
        return true
      } catch {
        try? FileManager.default.removeItem(at: part)
      }
    }
    guard type.conforms(to: .image),
          let image = await bareImage(provider, type),
          let data = image.jpegData(compressionQuality: 0.92)
    else { return false }
    return FileManager.default.createFile(
      atPath: inbox.appendingPathComponent("\(name).jpg").path,
      contents: data
    )
  }

  /// A copy the caller owns: the provider deletes its own file on return.
  private static func fileURL(_ provider: NSItemProvider, _ type: UTType) async -> URL? {
    await withCheckedContinuation { done in
      provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
        guard let url else { return done.resume(returning: nil) }
        let held = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString)
          .appendingPathExtension(url.pathExtension)
        do {
          try FileManager.default.copyItem(at: url, to: held)
          done.resume(returning: held)
        } catch {
          done.resume(returning: nil)
        }
      }
    }
  }

  private static func bareImage(_ provider: NSItemProvider, _ type: UTType) async -> UIImage? {
    await withCheckedContinuation { done in
      provider.loadItem(forTypeIdentifier: type.identifier) { item, _ in
        switch item {
        case let image as UIImage: done.resume(returning: image)
        case let data as Data: done.resume(returning: UIImage(data: data))
        case let url as URL: done.resume(returning: UIImage(contentsOfFile: url.path))
        default: done.resume(returning: nil)
        }
      }
    }
  }
}
