import UIKit
import UniformTypeIdentifiers

/// Share Extension entry point. Pulls the shared URL (or a URL inside shared
/// text), hands it to the app via the App Group, opens the app, and finishes.
/// It deliberately does no downloading itself — extensions have a tight memory
/// budget and the yt-dlp/Python engine lives in the main app.
class ShareViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        handleShare()
    }

    private func handleShare() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let providers = item.attachments else {
            return complete()
        }

        let urlType = UTType.url.identifier
        let textType = UTType.plainText.identifier

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(urlType) }) {
            provider.loadItem(forTypeIdentifier: urlType, options: nil) { [weak self] data, _ in
                self?.finish(with: (data as? URL)?.absoluteString)
            }
        } else if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(textType) }) {
            provider.loadItem(forTypeIdentifier: textType, options: nil) { [weak self] data, _ in
                let urlString = (data as? String).flatMap { Self.firstURL(in: $0) }
                self?.finish(with: urlString)
            }
        } else {
            complete()
        }
    }

    private func finish(with urlString: String?) {
        if let urlString {
            SharedInbox.add(urlString)
            openHostApp()
        }
        complete()
    }

    /// Extensions can't call `UIApplication.open` directly, so walk the responder
    /// chain to the application and invoke the (legacy) `openURL:` selector with
    /// our custom scheme to bring the main app forward.
    private func openHostApp() {
        guard let url = URL(string: "offlinelisten://import") else { return }
        let selector = sel_registerName("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                current.perform(selector, with: url)
                return
            }
            responder = current.next
        }
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private static func firstURL(in text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.firstMatch(in: text, range: range)?.url?.absoluteString
    }
}
