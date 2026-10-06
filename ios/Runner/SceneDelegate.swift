import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func sceneDidEnterBackground(_ scene: UIScene) {
    BackgroundSync.schedule()
    super.sceneDidEnterBackground(scene)
  }
}
