import Foundation
import UIKit

/// Something attached to the next prompt with the + menu.
struct PendingAttachment: Identifiable, Equatable {
    enum Kind: Equatable {
        /// A JPEG data URL, sent to the model as an image part.
        case image(String)
        /// A text file, inlined into the prompt.
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
        case .text: return "doc.text"
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
