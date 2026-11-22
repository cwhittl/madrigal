import Foundation
import SwiftData

/// Unused: nothing creates attachments yet. Kept only because the CloudKit
/// schema is additive-only and this model shipped in v1. Don't build on it
/// without revisiting the design (spec section 9) first.
@Model
final class Attachment {
    var filename: String = ""
    var mimeType: String = ""
    var data: Data = Data()          // small files only, see spec section 9
    var message: Message? = nil

    init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}
