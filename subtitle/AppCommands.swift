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

        CommandMenu("日志") {
            Button("导出文本日志…") {
                vm.exportLogs()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(!vm.hasExportableLog)

            Button("导出 SRT 字幕…") {
                vm.exportSRT()
            }
            .keyboardShortcut("s", modifiers: [.command, .option, .control])
            .disabled(!vm.hasExportableCaptions)

            Button("清空日志") {
                vm.clearLogs()
            }
            .disabled(!vm.hasExportableLog)
        }
    }
}
