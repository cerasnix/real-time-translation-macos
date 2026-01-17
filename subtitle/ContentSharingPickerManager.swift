import Foundation
import ScreenCaptureKit
import AppKit

enum ContentSharingPickerError: Error {
    case cancelled
    case inProgress
    case startFailed
}

@MainActor
final class ContentSharingPickerManager: NSObject, SCContentSharingPickerObserver {
    static let shared = ContentSharingPickerManager()

    private var continuation: CheckedContinuation<SCContentFilter, Error>?
    private var isPresenting: Bool = false
    private var presentTimeoutTask: Task<Void, Never>?
    private var activationObserver: Any?
    private var hasPresented: Bool = false

    func requestFilter() async throws -> SCContentFilter {
        let picker = SCContentSharingPicker.shared

        if isPresenting {
            if !picker.isActive {
                continuation?.resume(throwing: ContentSharingPickerError.startFailed)
                cleanup()
            } else {
                throw ContentSharingPickerError.inProgress
            }
        }

        isPresenting = true
        hasPresented = false
        picker.add(self)

        var config = picker.configuration ?? SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleDisplay]
        config.allowsChangingSelectedContent = false
        config.excludedBundleIDs = [Bundle.main.bundleIdentifier].compactMap { $0 }
        picker.configuration = config

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            schedulePresentation()
            presentTimeoutTask?.cancel()
            presentTimeoutTask = Task { [weak weakSelf = self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let strongSelf = weakSelf, strongSelf.isPresenting, !picker.isActive else { return }
                strongSelf.resolve(with: ContentSharingPickerError.startFailed)
            }
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        resolve(with: filter)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        resolve(with: ContentSharingPickerError.cancelled)
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        resolve(with: error)
    }

    private func resolve(with filter: SCContentFilter) {
        continuation?.resume(returning: filter)
        cleanup()
    }

    private func resolve(with error: Error) {
        continuation?.resume(throwing: error)
        cleanup()
    }

    private func cleanup() {
        SCContentSharingPicker.shared.remove(self)
        continuation = nil
        isPresenting = false
        hasPresented = false
        presentTimeoutTask?.cancel()
        presentTimeoutTask = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }
}

@MainActor
private extension ContentSharingPickerManager {
    func schedulePresentation() {
        if NSApp.isActive {
            presentPicker()
        } else {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak weakSelf = self] _ in
                guard let strongSelf = weakSelf else { return }
                Task { @MainActor in
                    strongSelf.presentPicker()
                }
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func presentPicker() {
        guard isPresenting, !hasPresented else { return }
        hasPresented = true
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        SCContentSharingPicker.shared.present(using: .display)
    }
}
