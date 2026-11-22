#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#elseif canImport(AppKit)
import AppKit
#endif

enum Clipboard {
    @MainActor
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    /// Rich text plus a plain-text fallback, so apps that take styles get them.
    @MainActor
    static func copy(_ text: NSAttributedString) {
        let range = NSRange(location: 0, length: text.length)
        let rtf = try? text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        #if canImport(UIKit)
        var item: [String: Any] = [UTType.utf8PlainText.identifier: text.string]
        if let rtf { item[UTType.rtf.identifier] = rtf }
        UIPasteboard.general.setItems([item])
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        if let rtf { NSPasteboard.general.setData(rtf, forType: .rtf) }
        NSPasteboard.general.setString(text.string, forType: .string)
        #endif
    }
}
