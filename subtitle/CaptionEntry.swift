import Foundation

struct CaptionEntry: Identifiable, Equatable {
    let id: UUID
    var original: String
    var translated: String

    init(id: UUID = UUID(), original: String, translated: String = "") {
        self.id = id
        self.original = original
        self.translated = translated
    }
}
