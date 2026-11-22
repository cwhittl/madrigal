import Foundation
import SwiftData

@Model
final class ProjectFile {
    var filename: String = ""
    var extractedText: String = ""   // plain text injected into context
    var addedAt: Date = Date.now
    var project: Project? = nil

    init(filename: String, extractedText: String) {
        self.filename = filename
        self.extractedText = extractedText
    }

    var characterCount: Int { extractedText.count }
}
