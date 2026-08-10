import SafariServices
import os.log

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey]
        os_log(.default, "Safari extension message received: %@", "\(message ?? "nil")")

        if let dict = message as? [String: Any],
           let urlStr = dict["openUrl"] as? String,
           let url = URL(string: urlStr) {
            context.open(url) { success in
                os_log(.default, "Opened XDM app URL scheme: %d", success)
            }
        }

        let response = NSExtensionItem()
        response.userInfo = [ SFExtensionMessageKey: [ "response": "ok" ] ]

        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
