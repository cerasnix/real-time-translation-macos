import SwiftUI

struct AppCommands: Commands {
    @ObservedObject private var vm: ViewModel

    init(vm: ViewModel) {
        self.vm = vm
    }

    var body: some Commands {
        CommandMenu("字幕控制") {
            if vm.isRunning {
                Button("停止") { vm.stop() }
                    .keyboardShortcut(.space, modifiers: [.command, .shift])
            } else {
                Button("开始") { vm.start() }
                    .keyboardShortcut(.space, modifiers: [.command, .shift])
            }
        }
    }
}
