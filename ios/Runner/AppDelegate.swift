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
      XDMTorrentBackgroundManager.shared.registerBackgroundTask()

      if let messenger = engineBridge.pluginRegistry.registrar(forPlugin: "XDMTorrentBackground")?.messenger() {
        let torrentBgChannel = FlutterMethodChannel(
          name: "com.dmx.app/torrent_background",
          binaryMessenger: messenger
        )

        torrentBgChannel.setMethodCallHandler { call, result in
          switch call.method {
          case "saveTorrentResumeData":
            guard let args = call.arguments as? [String: Any],
                  let torrentId = args["torrentId"] as? Int,
                  let data = args["data"] as? FlutterStandardTypedData else {
              result(false)
              return
            }
            XDMTorrentBackgroundManager.shared.saveTorrentResumeData(
              torrentId: torrentId,
              data: data.data
            )
            result(true)

          case "loadTorrentResumeData":
            guard let args = call.arguments as? [String: Any],
                  let torrentId = args["torrentId"] as? Int else {
              result(nil)
              return
            }
            let data = XDMTorrentBackgroundManager.shared.loadTorrentResumeData(
              torrentId: torrentId
            )
            result(data != nil ? FlutterStandardTypedData(bytes: data!) : nil)

          case "getActiveTorrentIds":
            let ids = XDMTorrentBackgroundManager.shared.getActiveTorrentIds()
            result(ids)

          default:
            result(FlutterMethodNotImplemented)
          }
        }
      }
    }
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    if #available(iOS 13.0, *) {
      let activeIds = XDMTorrentBackgroundManager.shared.getActiveTorrentIds()
      XDMTorrentBackgroundManager.shared.appDidEnterBackground(activeTorrentIds: activeIds)
    }
    super.applicationDidEnterBackground(application)
  }

  override func applicationWillEnterForeground(_ application: UIApplication) {
    if #available(iOS 13.0, *) {
      XDMTorrentBackgroundManager.shared.appWillEnterForeground()
    }
    super.applicationWillEnterForeground(application)
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
