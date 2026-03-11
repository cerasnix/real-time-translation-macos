import Foundation

struct CaptionEntry: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    var original: String
    var translated: String

    init(id: UUID = UUID(), createdAt: Date = Date(), original: String, translated: String = "") {
        self.id = id
        self.createdAt = createdAt
        self.original = original
        self.translated = translated
    }
}
