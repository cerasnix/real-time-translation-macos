import AppKit
import Combine

final class OverlayState: ObservableObject {
    @Published var dragEnabled: Bool = false
    // Normalized position (0..1) in screen coordinates, from bottom-left origin
    @Published var xRatio: CGFloat = 0.5
    @Published var yRatio: CGFloat = 0.12
}

struct OverlayContentSnapshot {
    var currentOriginal: String = ""
    var currentTranslated: String = ""
    var recentEntries: [CaptionEntry] = []
}

@MainActor
final class OverlayContentState: ObservableObject {
    @Published var currentOriginal: String = ""
    @Published var currentTranslated: String = ""
    @Published var recentEntries: [CaptionEntry] = []

    func apply(snapshot: OverlayContentSnapshot) {
        currentOriginal = snapshot.currentOriginal
        currentTranslated = snapshot.currentTranslated
        recentEntries = snapshot.recentEntries
    }

    func reset() {
        apply(snapshot: OverlayContentSnapshot())
    }
}
