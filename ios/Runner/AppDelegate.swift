import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "VisionAnalysisChannel"
    ) {
      VisionAnalysisChannel.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "ICloudDriveChannel"
    ) {
      ICloudDriveChannel.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "StillVideoChannel"
    ) {
      StillVideoChannel.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "DocumentTextChannel"
    ) {
      DocumentTextChannel.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "BackupExclusionChannel"
    ) {
      BackupExclusionChannel.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "PrivacyCoverChannel"
    ) {
      PrivacyCoverChannel.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "AppStoreRegionChannel"
    ) {
      // Info.plist AppStoreRegion (`make ... STOREFRONT=CHN`), whether a
      // language was picked for this app in iOS Settings, and the one
      // picked inside the app.
      FlutterMethodChannel(
        name: "byo.photos/app_store",
        binaryMessenger: registrar.messenger()
      ).setMethodCallHandler { call, result in
        switch call.method {
        case "region":
          result(Bundle.main.object(forInfoDictionaryKey: "AppStoreRegion"))
        case "languageChosen":
          let domain = UserDefaults.standard.persistentDomain(
            forName: Bundle.main.bundleIdentifier ?? ""
          )
          result(domain?["AppleLanguages"] != nil)
        case "language":
          result(UserDefaults.standard.string(forKey: "appLanguage"))
        case "setLanguage":
          if let code = call.arguments as? String {
            UserDefaults.standard.set(code, forKey: "appLanguage")
          } else {
            UserDefaults.standard.removeObject(forKey: "appLanguage")
          }
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }
}
