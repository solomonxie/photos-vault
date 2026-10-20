import Security
import UIKit
import UniformTypeIdentifiers

/// "Photos Vault" in the share sheet. Everything shared goes to a hidden
/// album: asks for its code, copies the items into the App Group's inbox
/// as one batch, and closes. The app files a batch on its
/// next open without asking again (`lib/photos/share_inbox.dart`). Nothing
/// here touches Photos.
///
/// The inbox is plain files, out of the device backup, until the app takes
/// them. A hidden batch's code waits in the Keychain (this device only,
/// never backed up) and is deleted once filed: the one place a code is
/// kept, for that window only. Kept to copying: the hide path is Dart, and
/// an extension gets ~120 MB of memory.
class ShareViewController: UIViewController {
  private let panel = SharePanel()

  /// A card at the bottom over the app being shared from — not a full
  /// screen, and not a second sheet presented on top (that waited for this
  /// one's animation to finish, and went full height for the keyboard). It
  /// rides in with the share sheet's own slide and sits on the keyboard.
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = UIColor.black.withAlphaComponent(0.2)
    let outside = UITapGestureRecognizer(target: self, action: #selector(tappedOutside))
    outside.cancelsTouchesInView = false
    view.addGestureRecognizer(outside)
    panel.context = extensionContext
    addChild(panel)
    let card = panel.view!
    card.translatesAutoresizingMaskIntoConstraints = false
    card.layer.cornerRadius = 16
    card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    view.addSubview(card)
    NSLayoutConstraint.activate([
      card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      card.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      panel.contentBottom.constraint(
        equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16
      ),
    ])
    panel.didMove(toParent: self)
  }

  @objc private func tappedOutside(_ tap: UITapGestureRecognizer) {
    guard !panel.saving,
          !panel.view.frame.contains(tap.location(in: view))
    else { return }
    extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
  }
}

final class SharePanel: UIViewController, UITextFieldDelegate {
  weak var context: NSExtensionContext?
  private(set) var saving = false
  private let stack = UIStackView()
  var contentBottom: NSLayoutYAxisAnchor { stack.bottomAnchor }
  private let message = UILabel()
  private let codeField = UITextField()
  private weak var hideButton: UIButton?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    stack.axis = .vertical
    stack.spacing = 14
    stack.alignment = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    let guide = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
    ])
    message.numberOfLines = 0
    message.textAlignment = .center
    message.font = .preferredFont(forTextStyle: .body)
    message.adjustsFontForContentSizeCategory = true
    askCode()
  }

  private func reset(_ title: String, _ text: String?) {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    let heading = UILabel()
    heading.text = title
    heading.textAlignment = .center
    heading.numberOfLines = 0
    heading.font = .preferredFont(forTextStyle: .headline)
    stack.addArrangedSubview(heading)
    message.text = text
    message.textColor = .secondaryLabel
    if text != nil { stack.addArrangedSubview(message) }
  }

  private func button(_ title: String, prominent: Bool = false,
                      _ action: @escaping () -> Void) -> UIButton {
    var config = prominent ? UIButton.Configuration.filled() : .gray()
    config.title = title
    config.cornerStyle = .large
    config.buttonSize = .large
    let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
    stack.addArrangedSubview(button)
    return button
  }

  /// Once, in the clear: the digits stay visible so a typo can be seen and
  /// fixed before Hide — every code opens *an* album, so a wrong one hides
  /// the photos somewhere nobody will look.
  private func askCode() {
    reset(
      NSLocalizedString("Hidden album code", comment: ""),
      NSLocalizedString("Enter the album's 4-digit code.", comment: "")
    )
    codeField.text = ""
    codeField.keyboardType = .numberPad
    codeField.textAlignment = .center
    codeField.font = .monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
    codeField.borderStyle = .roundedRect
    codeField.delegate = self
    codeField.removeTarget(nil, action: nil, for: .editingChanged)
    codeField.addTarget(self, action: #selector(codeChanged), for: .editingChanged)
    stack.addArrangedSubview(codeField)
    hideButton = button(NSLocalizedString("Hide", comment: ""), prominent: true) {
      [weak self] in
      guard let code = self?.codeField.text, code.count == 4 else { return }
      self?.view.endEditing(true)
      self?.save(code: code)
    }
    hideButton?.isEnabled = false
    _ = button(NSLocalizedString("Cancel", comment: "")) { [weak self] in
      self?.view.endEditing(true)
      self?.context?.cancelRequest(withError: CocoaError(.userCancelled))
    }
    codeField.becomeFirstResponder()
  }

  func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange,
                 replacementString string: String) -> Bool {
    let next = ((field.text ?? "") as NSString).replacingCharacters(in: range, with: string)
    return next.count <= 4 && next.allSatisfy(\.isNumber)
  }

  @objc private func codeChanged() {
    hideButton?.isEnabled = codeField.text?.count == 4
  }

  private func save(code: String) {
    saving = true
    reset(NSLocalizedString("Saving…", comment: ""), nil)
    let spinner = UIActivityIndicatorView(style: .large)
    spinner.startAnimating()
    stack.addArrangedSubview(spinner)
    Task { await finish(code: code) }
  }

  private func finish(code: String) async {
    let providers = (context?.inputItems as? [NSExtensionItem] ?? [])
      .flatMap { $0.attachments ?? [] }
    let saved = await ShareInbox.saveBatch(providers, code: code)
    if saved == 0 {
      reset(
        NSLocalizedString("Nothing saved", comment: ""),
        NSLocalizedString(
          "No photo or video here. To save an image from a web page, long-press it and share that.",
          comment: ""
        )
      )
    } else {
      reset(
        String.localizedStringWithFormat(NSLocalizedString("Saved %d", comment: ""), saved),
        NSLocalizedString("They'll be hidden next time you open Photos Vault.", comment: "")
      )
    }
    try? await Task.sleep(nanoseconds: saved == 0 ? 2_500_000_000 : 1_200_000_000)
    context?.completeRequest(returningItems: nil)
  }
}

enum ShareInbox {
  static var group: String? {
    // `group.<app id>`, as in both entitlements files. Derived, not read
    // from Info.plist: `$(APP_BUNDLE_ID)` doesn't expand there.
    Bundle.main.bundleIdentifier.map {
      "group." + $0.replacingOccurrences(of: ".ShareExtension", with: "")
    }
  }

  /// One folder per share plus `<batch>.json` naming where it goes,
  /// written last: the app takes a batch only once its manifest exists.
  static func saveBatch(_ providers: [NSItemProvider], code: String) async -> Int {
    guard let inbox = directory() else { return 0 }
    let batch = UUID().uuidString
    let folder = inbox.appendingPathComponent(batch, isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var saved = 0
    for provider in providers {
      if await copy(provider, into: folder) { saved += 1 }
    }
    guard saved > 0, storeCode(code, ref: batch) else {
      try? FileManager.default.removeItem(at: folder)
      return 0
    }
    let manifest: [String: Any] = ["destination": "hidden"]
    guard let data = try? JSONSerialization.data(withJSONObject: manifest),
          FileManager.default.createFile(
            atPath: inbox.appendingPathComponent("\(batch).json").path,
            contents: data
          )
    else {
      try? FileManager.default.removeItem(at: folder)
      return 0
    }
    return saved
  }

  /// Read and deleted by `ShareInboxChannel.takeCode` in the app.
  private static func storeCode(_ code: String, ref: String) -> Bool {
    guard let group else { return false }
    let status = SecItemAdd([
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: "share-inbox",
      kSecAttrAccount: ref,
      kSecAttrAccessGroup: group,
      kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecValueData: Data(code.utf8),
    ] as CFDictionary, nil)
    return status == errSecSuccess
  }

  static func directory() -> URL? {
    guard let group,
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
    guard let type = wanted else {
      // Safari hands some images over as their address only.
      guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
            let url = await webURL(provider)
      else { return false }
      return await download(url, into: inbox)
    }
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

  private static func webURL(_ provider: NSItemProvider) async -> URL? {
    await withCheckedContinuation { done in
      provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
        done.resume(returning: item as? URL)
      }
    }
  }

  /// Kept only when the server says it's an image or a video; a web page
  /// is refused, not saved.
  private static func download(_ url: URL, into inbox: URL) async -> Bool {
    if url.isFileURL {
      guard let type = UTType(filenameExtension: url.pathExtension),
            type.conforms(to: .image) || type.conforms(to: .movie)
      else { return false }
      return (try? FileManager.default.copyItem(
        at: url,
        to: inbox.appendingPathComponent("\(UUID().uuidString).\(url.pathExtension.lowercased())")
      )) != nil
    }
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          let (file, response) = try? await URLSession.shared.download(from: url)
            as (URL, URLResponse)?
    else { return false }
    defer { try? FileManager.default.removeItem(at: file) }
    guard let mime = response.mimeType,
          let type = UTType(mimeType: mime),
          type.conforms(to: .image) || type.conforms(to: .movie),
          let ext = type.preferredFilenameExtension
    else { return false }
    let name = UUID().uuidString
    let part = inbox.appendingPathComponent("\(name).part")
    do {
      try FileManager.default.moveItem(at: file, to: part)
      try FileManager.default.moveItem(
        at: part,
        to: inbox.appendingPathComponent("\(name).\(ext)")
      )
      return true
    } catch {
      try? FileManager.default.removeItem(at: part)
      return false
    }
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
