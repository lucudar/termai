import Foundation
import PDFKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Something attached to the next prompt with the + menu.
struct PendingAttachment: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A JPEG data URL, sent to the model as an image part.
        case image(String)
        /// A text file (or the text of a PDF), inlined into the prompt.
        case text(String)
        /// Any other file, copied into the on-device workspace at this relative path.
        case file(String)
    }

    let id = UUID()
    var name: String
    var kind: Kind
    /// Type and size, or where it was saved, under the name in its chip.
    var detail: String = ""

    var isImage: Bool {
        if case .image = kind { return true }
        return false
    }

    var symbol: String {
        switch kind {
        case .image: return "photo"
        case .text: return name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc.text"
        case .file: return "doc"
        }
    }
}

enum ImageAttachment {
    /// Scales an image down to `maxSide` pixels and encodes it as a JPEG data URL, or nil if it is not an image.
    static func dataURL(from data: Data, maxSide: CGFloat = 1_536) -> String? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, (image.size.width * scale).rounded()),
                          height: max(1, (image.size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            // JPEG has no alpha; transparent screenshots get a white backdrop instead of black.
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { return nil }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }
}

/// Turns a picked file into an attachment. Runs off the main thread.
enum FileAttachment {
    /// Larger text goes to the workspace instead of the prompt.
    static let inlineLimit = 400_000

    /// Images become image parts, text and PDF text are inlined, anything else is copied to `inbox`.
    static func load(_ url: URL, inbox: URL) throws -> PendingAttachment {
        let name = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
            removeIfTemporary(url)
        }
        let data = try Data(contentsOf: url)
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)

        if type?.conforms(to: .image) == true || type == nil, let image = ImageAttachment.dataURL(from: data) {
            return PendingAttachment(name: name, kind: .image(image), detail: "image, \(size)")
        }
        if type?.conforms(to: .pdf) == true, let document = PDFDocument(data: data), let text = document.string,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= inlineLimit {
            let pages = document.pageCount == 1 ? "1 page" : "\(document.pageCount) pages"
            return PendingAttachment(name: name, kind: .text(text), detail: "PDF text, \(pages)")
        }
        if data.count <= inlineLimit, !data.contains(0), let text = String(data: data, encoding: .utf8) {
            return PendingAttachment(name: name, kind: .text(text), detail: "text, \(size)")
        }
        let path = try copy(data, named: name, into: inbox)
        return PendingAttachment(name: name, kind: .file(path), detail: "\(size), saved as \(path)")
    }

    /// Saves `data` as `Inbox/<name>`, or `Inbox/<name> 2` and so on when that exists. Returns the relative path.
    static func copy(_ data: Data, named name: String, into inbox: URL) throws -> String {
        let files = FileManager.default
        try files.createDirectory(at: inbox, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension
        let suffix = (name as NSString).pathExtension
        var candidate = name
        var number = 2
        while files.fileExists(atPath: inbox.appendingPathComponent(candidate).path) {
            candidate = suffix.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(suffix)"
            number += 1
        }
        try data.write(to: inbox.appendingPathComponent(candidate), options: .atomic)
        return "Inbox/" + candidate
    }

    /// The document picker hands over private copies in the app's temporary folder; they are not needed afterwards.
    static func removeIfTemporary(_ url: URL) {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        if url.resolvingSymlinksInPath().path.hasPrefix(temporary) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// The system document picker, presented by UIKit over whatever is on screen rather than from a SwiftUI
/// sheet. It copies what is picked into the app, so iCloud and other providers whose files are not on the
/// device yet work too.
enum DocumentPicker {
    @MainActor
    static func present(onPick: @escaping ([URL]) -> Void) {
        guard let top = topViewController() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        let delegate = Delegate(onPick: onPick)
        picker.delegate = delegate
        top.present(picker, animated: true)
    }

    /// The screen on top: the window's root view controller, or whatever it is presenting.
    @MainActor
    static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    /// The picker holds its delegate weakly, so the delegate keeps itself alive until the picker is done.
    final class Delegate: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void
        private var keepAlive: Delegate?

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
            super.init()
            keepAlive = self
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
            keepAlive = nil
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            keepAlive = nil
        }
    }
}
