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
struct XDMShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDownloadIntent(),
            phrases: ["Download \(\.$url) with XDM"],
            shortTitle: "Download URL",
            systemImageName: "arrow.down.circle"
        )
    }
}
