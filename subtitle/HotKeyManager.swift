import Foundation
import Combine
import Carbon.HIToolbox

final class HotKeyManager: ObservableObject {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    var onHotKey: (() -> Void)?

    init() {
        registerHotKey()
    }

    deinit {
        unregisterHotKey()
    }

    func bind(to viewModel: ViewModel) {
        onHotKey = { [weak viewModel] in
            Task { @MainActor in
                viewModel?.toggle()
            }
        }
    }

    private func registerHotKey() {
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        let modifiers = UInt32(cmdKey | shiftKey)
        let keyCode = UInt32(kVK_Space)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            debugLog("[ERROR] RegisterEventHotKey failed: \(status)")
        }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(GetApplicationEventTarget(),
                            Self.eventHandlerUPP,
                            1,
                            &eventType,
                            selfPointer,
                            &eventHandler)
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        hotKeyRef = nil
        eventHandler = nil
    }

    private func handleHotKey() {
        onHotKey?()
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print(message)
        #endif
    }

    private static let eventHandlerUPP: EventHandlerUPP = { _, _, userData in
        guard let userData else { return noErr }
        let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
        manager.handleHotKey()
        return noErr
    }

    private static let hotKeySignature: OSType = {
        var value: UInt32 = 0
        for scalar in Array("SUBT".utf8) {
            value = (value << 8) + UInt32(scalar)
        }
        return value
    }()
}
