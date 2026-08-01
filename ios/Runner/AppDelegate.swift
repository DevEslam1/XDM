import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
      registerNotificationCategories()
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if #available(iOS 13.0, *) {
      IosBackgroundDownloadHandler.register(with: engineBridge.pluginRegistry.registrar(forPlugin: "IosBackgroundDownloadHandler")!)
    }
  }

  override func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    if #available(iOS 13.0, *) {
      XDMBackgroundDownloadManager.shared.backgroundCompletionHandler = completionHandler
    } else {
      completionHandler()
    }
  }

  private func registerNotificationCategories() {
    if #available(iOS 10.0, *) {
      let pauseAction = UNNotificationAction(
        identifier: "XDM_ACTION_PAUSE",
        title: "Pause",
        options: []
      )
      let resumeAction = UNNotificationAction(
        identifier: "XDM_ACTION_RESUME",
        title: "Resume",
        options: []
      )
      let cancelAction = UNNotificationAction(
        identifier: "XDM_ACTION_CANCEL",
        title: "Cancel",
        options: [.destructive]
      )

      let category = UNNotificationCategory(
        identifier: "XDM_DOWNLOAD_CATEGORY",
        actions: [pauseAction, resumeAction, cancelAction],
        intentIdentifiers: [],
        options: [.customDismissAction]
      )

      UNUserNotificationCenter.current().setNotificationCategories([category])
    }
  }

  @available(iOS 10.0, *)
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    if let taskId = userInfo["taskId"] as? String {
      let actionId = response.actionIdentifier
      if #available(iOS 13.0, *) {
        switch actionId {
        case "XDM_ACTION_PAUSE":
          XDMBackgroundDownloadManager.shared.pauseDownload(taskId: taskId)
        case "XDM_ACTION_RESUME":
          if let urlStr = userInfo["url"] as? String, let path = userInfo["destinationPath"] as? String {
            XDMBackgroundDownloadManager.shared.resumeDownload(taskId: taskId, urlStr: urlStr, destinationPath: path)
          }
        case "XDM_ACTION_CANCEL":
          XDMBackgroundDownloadManager.shared.cancelDownload(taskId: taskId)
        default:
          break
        }
      }
    }
    super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
  }
}
