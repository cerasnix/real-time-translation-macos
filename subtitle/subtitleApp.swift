import SwiftUI

@main
struct subtitleApp: App {
    @StateObject private var vm: ViewModel
    @StateObject private var hotKeyManager: HotKeyManager

    init() {
        let vm = ViewModel()
        let hotKeyManager = HotKeyManager()
        hotKeyManager.bind(to: vm)
        _vm = StateObject(wrappedValue: vm)
        _hotKeyManager = StateObject(wrappedValue: hotKeyManager)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
        }
        .commands {
            AppCommands(vm: vm)
        }
    }
}
