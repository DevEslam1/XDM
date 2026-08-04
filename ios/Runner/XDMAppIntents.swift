import AppIntents
import UIKit

@available(iOS 16.0, *)
struct StartDownloadIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Download"
    static var description = IntentDescription("Start a download with a URL in XDM")

    @Parameter(title: "URL")
    var url: String

    func perform() async throws -> some IntentResult {
        let encoded = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url
        if let appURL = URL(string: "dmx://share?url=\(encoded)") {
            await UIApplication.shared.open(appURL)
        }
        return .result()
    }
}

@available(iOS 16.0, *)
struct PauseAllDownloadsIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause All Downloads"
    static var description = IntentDescription("Pause all active downloads in XDM")

    func perform() async throws -> some IntentResult {
        UserDefaults(suiteName: "group.com.dmx.app")?.set(true, forKey: "xdm_pause_all")
        return .result()
    }
}

@available(iOS 16.0, *)
struct ResumeAllDownloadsIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume All Downloads"
    static var description = IntentDescription("Resume all paused downloads in XDM")

    func perform() async throws -> some IntentResult {
        UserDefaults(suiteName: "group.com.dmx.app")?.set(true, forKey: "xdm_resume_all")
        return .result()
    }
}

@available(iOS 16.0, *)
struct GetDownloadStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Download Status"
    static var description = IntentDescription("Returns the count of active downloads in XDM")

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let count = UserDefaults(suiteName: "group.com.dmx.app")?.integer(forKey: "xdm_active_downloads_count") ?? 0
        return .result(value: count)
    }
}

@available(iOS 16.0, *)
struct DownloadFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Download File"
    static var description = IntentDescription("Download a file with an optional file name in XDM")

    @Parameter(title: "URL")
    var url: String

    @Parameter(title: "File Name")
    var fileName: String?

    func perform() async throws -> some IntentResult {
        let encodedUrl = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url
        var urlString = "dmx://add?url=\(encodedUrl)"
        if let name = fileName, !name.isEmpty,
           let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            urlString += "&name=\(encodedName)"
        }
        if let appURL = URL(string: urlString) {
            await UIApplication.shared.open(appURL)
        }
        return .result()
    }
}

@available(iOS 16.0, *)
struct XDMShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDownloadIntent(),
            phrases: ["Download \(\.$url) with XDM"],
            shortTitle: "Download URL",
            systemImageName: "arrow.down.circle"
        )
        AppShortcut(
            intent: PauseAllDownloadsIntent(),
            phrases: ["Pause all downloads in XDM"],
            shortTitle: "Pause All Downloads",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: ResumeAllDownloadsIntent(),
            phrases: ["Resume all downloads in XDM"],
            shortTitle: "Resume All Downloads",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: GetDownloadStatusIntent(),
            phrases: ["Get download status in XDM"],
            shortTitle: "Get Download Status",
            systemImageName: "info.circle"
        )
        AppShortcut(
            intent: DownloadFileIntent(),
            phrases: ["Download file \(\.$url) with XDM"],
            shortTitle: "Download File",
            systemImageName: "arrow.down.doc"
        )
    }
}
