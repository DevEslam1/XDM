import Foundation
import CoreSpotlight
import MobileCoreServices

/// Service for indexing completed download files into iOS Spotlight.
@available(iOS 9.0, *)
public class XDMSpotlightService: NSObject {
    public static let shared = XDMSpotlightService()

    /// Indexes a completed download item into iOS Spotlight.
    public func indexDownloadedFile(taskId: String, title: String, filePath: String, mimeType: String?) {
        let attributeSet = CSSearchableItemAttributeSet(itemContentType: (mimeType as CFString?) ?? kUTTypeData)
        attributeSet.title = title
        attributeSet.contentDescription = "Downloaded file managed by XDM"
        attributeSet.contentURL = URL(fileURLWithPath: filePath)
        
        let item = CSSearchableItem(
            uniqueIdentifier: taskId,
            domainIdentifier: "com.dmx.app.downloads",
            attributeSet: attributeSet
        )
        
        CSSearchableIndex.default().indexSearchableItems([item]) { error in
            if let error = error {
                print("XDM Spotlight Indexing Error: \(error.localizedDescription)")
            } else {
                print("XDM: Successfully indexed '\(title)' in Spotlight")
            }
        }
    }

    /// Removes an item from iOS Spotlight index.
    public func deindexFile(taskId: String) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [taskId]) { error in
            if let error = error {
                print("XDM Spotlight Deindex Error: \(error.localizedDescription)")
            }
        }
    }
}
