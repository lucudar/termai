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

        if type?.conforms(to: .image) == true || type == nil, let image = ImageAttachment.dataURL(from: data) {
            return PendingAttachment(name: name, kind: .image(image))
        }
        if type?.conforms(to: .pdf) == true, let text = PDFDocument(data: data)?.string,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= inlineLimit {
            return PendingAttachment(name: name, kind: .text(text))
        }
        if data.count <= inlineLimit, !data.contains(0), let text = String(data: data, encoding: .utf8) {
            return PendingAttachment(name: name, kind: .text(text))
        }
        let path = try copy(data, named: name, into: inbox)
        return PendingAttachment(name: name, kind: .file(path))
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

/// The system document picker, copying what is picked into the app. Copies work for iCloud and other
/// providers whose files are not on the device yet, which reading the originals in place does not.
struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
