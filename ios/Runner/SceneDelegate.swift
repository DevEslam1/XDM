import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func sceneDidEnterBackground(_ scene: UIScene) {
    // FIX(A-8): Single source of truth guard when scene-based lifecycle is active
    guard #available(iOS 13.0, *),
          UIApplication.shared.delegate is AppDelegate else { return }
    let manager = XDMTorrentBackgroundManager.shared
    manager.appDidEnterBackground(activeTorrentIds: manager.getActiveTorrentIds())
    super.sceneDidEnterBackground(scene)
  }


  override func sceneWillEnterForeground(_ scene: UIScene) {
    if #available(iOS 13.0, *) {
      XDMTorrentBackgroundManager.shared.appWillEnterForeground()
    }
    super.sceneWillEnterForeground(scene)
  }
}
