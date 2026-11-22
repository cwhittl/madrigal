import Foundation
import PDFKit
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Pulls plain text out of the file types a project's knowledge base accepts.
/// See spec section 9.
enum FileTextExtractor {

    static let perFileCharacterCap = 20_000

    static let supportedTypes: [UTType] = [
        .plainText, .pdf, .rtf, .commaSeparatedText, .json, .yaml,
        UTType(filenameExtension: "md") ?? .plainText
    ]

    enum ExtractionError: LocalizedError {
        case unreadable(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "Couldn't read \(name)."
            case .unsupported(let ext): return "\(ext) files aren't supported yet."
            }
        }
    }

    static func extractText(from url: URL) throws -> String {
        // Files picked through .fileImporter live outside the sandbox.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        let text: String

        switch ext {
        case "pdf":
            guard let document = PDFDocument(url: url) else {
                throw ExtractionError.unreadable(url.lastPathComponent)
            }
            var pages: [String] = []
            for index in 0..<document.pageCount {
                if let page = document.page(at: index), let string = page.string {
                    pages.append(string)
                }
            }
            text = pages.joined(separator: "\n\n")

        case "rtf":
            guard let data = try? Data(contentsOf: url),
                  let attributed = try? NSAttributedString(
                      data: data,
                      options: [.documentType: NSAttributedString.DocumentType.rtf],
                      documentAttributes: nil
                  ) else {
                throw ExtractionError.unreadable(url.lastPathComponent)
            }
            text = attributed.string

        case "txt", "md", "markdown", "csv", "json", "yaml", "yml", "":
            guard let string = try? String(contentsOf: url, encoding: .utf8) else {
                throw ExtractionError.unreadable(url.lastPathComponent)
            }
            text = string

        default:
            throw ExtractionError.unsupported(ext)
        }

        return cap(text)
    }

    static func cap(_ text: String) -> String {
        guard text.count > perFileCharacterCap else { return text }
        return String(text.prefix(perFileCharacterCap)) + "\n\n[truncated - file exceeded \(perFileCharacterCap) characters]"
    }
}
