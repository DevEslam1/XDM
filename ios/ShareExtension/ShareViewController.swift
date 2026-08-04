import UIKit
import Social
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        processSharedContent()
    }

    private func processSharedContent() {
        guard let extensionContext = extensionContext,
              let inputItem = extensionContext.inputItems.first as? NSExtensionItem,
              let attachments = inputItem.attachments else {
            close()
            return
        }

        for attachment in attachments {
            if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                attachment.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, _ in
                    DispatchQueue.main.async {
                        if let url = item as? URL {
                            self?.openMainApp(with: url.absoluteString)
                        } else {
                            self?.close()
                        }
                    }
                }
                return
            }

            if attachment.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                attachment.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] item, _ in
                    DispatchQueue.main.async {
                        if let text = item as? String {
                            let extracted = self?.extractUrlOrMagnet(from: text) ?? text
                            self?.openMainApp(with: extracted)
                        } else {
                            self?.close()
                        }
                    }
                }
                return
            }
        }
        close()
    }

    private func extractUrlOrMagnet(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "magnet:\\?[^\\s<\">]+", options: .regularExpression) {
            return String(trimmed[range])
        }
        if let range = trimmed.range(of: "https?://[^\\s<\">]+", options: .regularExpression) {
            return String(trimmed[range])
        }
        return trimmed
    }

    private func openMainApp(with urlString: String) {
        // FIX(A-10): Use URLComponents to build the URL safely with proper query encoding
        var components = URLComponents()
        components.scheme = "dmx"
        components.host   = "share"
        components.queryItems = [URLQueryItem(name: "url", value: urlString)]
        guard let appURL = components.url else { close(); return }


        var responder: UIResponder? = self
        while responder != nil {
            if let application = responder as? UIApplication {
                application.open(appURL, options: [:], completionHandler: nil)
                break
            }
            responder = responder?.next
        }
        close()
    }

    private func close() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
