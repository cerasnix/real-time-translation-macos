import SwiftUI
import AppKit

@available(macOS 26.0, *)
struct NativeGlassContainer<Content: View>: NSViewRepresentable {
    var cornerRadius: CGFloat
    var style: NSGlassEffectView.Style = .clear
    var tintColor: NSColor? = nil
    private let content: Content

    init(
        cornerRadius: CGFloat,
        style: NSGlassEffectView.Style = .clear,
        tintColor: NSColor? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.style = style
        self.tintColor = tintColor
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(rootView: content)
    }

    func makeNSView(context: Context) -> GlassContainerHostView {
        let containerView = GlassContainerHostView()
        updateContainerView(containerView, hostingView: context.coordinator.hostingView)
        return containerView
    }

    func updateNSView(_ nsView: GlassContainerHostView, context: Context) {
        let hostingView = context.coordinator.hostingView
        hostingView.rootView = content
        updateContainerView(nsView, hostingView: hostingView)
    }

    private func updateContainerView(_ containerView: GlassContainerHostView, hostingView: NSHostingView<Content>) {
        let glassView = containerView.glassView
        if glassView.style != style {
            glassView.style = style
        }

        if glassView.cornerRadius != cornerRadius {
            glassView.cornerRadius = cornerRadius
        }

        if !sameColor(glassView.tintColor, tintColor) {
            glassView.tintColor = tintColor
        }

        if glassView.contentView !== hostingView {
            glassView.contentView = hostingView
        }
    }

    private func sameColor(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.isEqual(rhs)
        default:
            return false
        }
    }

    final class Coordinator {
        let hostingView: NSHostingView<Content>

        init(rootView: Content) {
            self.hostingView = NSHostingView(rootView: rootView)
        }
    }

    final class GlassContainerHostView: NSGlassEffectContainerView {
        let glassView = NSGlassEffectView()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            spacing = 0
            contentView = glassView
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
