import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func sceneDidEnterBackground(_ scene: UIScene) {
    // FIX: When AppDelegate handles lifecycle, SceneDelegate should not duplicate it.
    // Only handle torrent background if AppDelegate is NOT handling it.
    if #available(iOS 13.0, *) {
      let manager = XDMTorrentBackgroundManager.shared
      manager.appDidEnterBackground(activeTorrentIds: manager.getActiveTorrentIds())
    }
    super.sceneDidEnterBackground(scene)
  }

  override func sceneWillEnterForeground(_ scene: UIScene) {
    if #available(iOS 13.0, *) {
      XDMTorrentBackgroundManager.shared.appWillEnterForeground()
    }
    super.sceneWillEnterForeground(scene)
  }
}
