import Flutter
import UIKit
import UserNotifications
import BackgroundTasks

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

    // Register background task handlers BEFORE the Flutter engine is set up
    // so a background launch always has its handlers in place.
    if #available(iOS 13.0, *) {
      BGTaskScheduler.shared.register(
        forTaskWithIdentifier: "com.dmx.app.download",
        using: nil
      ) { task in
        IosBackgroundDownloadHandler.shared.handleDownloadTask(task: task as! BGProcessingTask)
      }

      BGTaskScheduler.shared.register(
        forTaskWithIdentifier: "com.dmx.app.torrent.refresh",
        using: nil
      ) { task in
        XDMTorrentBackgroundManager.shared.handleTorrentRefreshTask(task: task as! BGProcessingTask)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if #available(iOS 13.0, *) {
      IosBackgroundDownloadHandler.register(with: engineBridge.pluginRegistry.registrar(forPlugin: "IosBackgroundDownloadHandler")!)

      if let messenger = engineBridge.pluginRegistry.registrar(forPlugin: "XDMWidgetBridge")?.messenger() {
        let widgetBridgeChannel = FlutterMethodChannel(
          name: "com.dmx.app/widget_bridge",
          binaryMessenger: messenger
        )
        widgetBridgeChannel.setMethodCallHandler { call, result in
          switch call.method {
          case "pushDashboard":
            guard let json = call.arguments as? String else {
              result(false)
              return
            }
            XDMWidgetDataStore.shared.saveDashboardJson(json)
            result(true)
          case "getFreeDiskSpace":
            let space = XDMWidgetDataStore.shared.getFreeDiskSpace()
            result(space)
          default:
            result(FlutterMethodNotImplemented)
          }
        }
      }

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

          case "setActiveTorrentIds":
            guard let args = call.arguments as? [String: Any],
                  let ids = args["ids"] as? [Int] else {
              result(false)
              return
            }
            XDMTorrentBackgroundManager.shared.setActiveTorrentIds(ids)
            result(true)

          case "appDidEnterBackground":
            XDMTorrentBackgroundManager.shared.appDidEnterBackground(
              activeTorrentIds: XDMTorrentBackgroundManager.shared.getActiveTorrentIds()
            )
            result(true)

          case "appWillEnterForeground":
            XDMTorrentBackgroundManager.shared.appWillEnterForeground()
            result(true)

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
      // Keep active downloads moving: schedule the download processing task
      // so iOS wakes us when network conditions allow.
      if XDMBackgroundDownloadManager.shared.hasActiveDownloads() {
        IosBackgroundDownloadHandler.shared.scheduleBackgroundProcessing()
      }
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
