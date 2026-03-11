import SwiftUI

struct SubtitleSettingsView: View {
    @EnvironmentObject private var vm: ViewModel

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("实时字幕会记住这些偏好设置。")
                        .font(.headline)
                    Text("所有调整都会立即同步到主窗口预览和悬浮字幕。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("语言") {
                Picker("源语言", selection: $vm.translationSource) {
                    ForEach(sourceLanguageOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                }

                Picker("目标语言", selection: $vm.translationTarget) {
                    ForEach(targetLanguageOptions) { option in
                        Text(option.title).tag(option.id)
                    }
                }
            }

            Section("显示") {
                LabeledContent("字幕条数") {
                    Stepper(value: $vm.maxLines, in: 1...10) {
                        Text("\(vm.maxLines)")
                            .monospacedDigit()
                    }
                    .frame(width: 72, alignment: .trailing)
                }

                LabeledContent("字体大小") {
                    Stepper(value: $vm.fontSize, in: 12...48, step: 2) {
                        Text("\(Int(vm.fontSize)) pt")
                            .monospacedDigit()
                    }
                    .frame(width: 96, alignment: .trailing)
                }
            }

            Section("外观") {
                Picker("背景风格", selection: $vm.backgroundStyle) {
                    ForEach(OverlayBackgroundStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent(vm.backgroundStyle == .glass ? "Tint 强度" : "透明度") {
                    HStack(spacing: 10) {
                        Slider(value: $vm.backgroundOpacity, in: 0.2...1.0)
                            .frame(width: 170)
                        Text("\(Int(vm.backgroundOpacity * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Section("快捷键") {
                LabeledContent("切换捕获") {
                    Text("Shift+Space")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LanguageOption: Identifiable {
    let id: String
    let title: String
}

private let sourceLanguageOptions: [LanguageOption] = [
    LanguageOption(id: "en", title: "英语 (English)"),
    LanguageOption(id: "ja", title: "日语 (日本語)"),
    LanguageOption(id: "zh-Hans", title: "中文 (简体)"),
    LanguageOption(id: "zh-Hant", title: "中文 (繁体)"),
    LanguageOption(id: "ko", title: "韩语 (한국어)"),
    LanguageOption(id: "fr", title: "法语 (Français)"),
    LanguageOption(id: "de", title: "德语 (Deutsch)"),
    LanguageOption(id: "es", title: "西班牙语 (Español)"),
    LanguageOption(id: "ru", title: "俄语 (Русский)"),
    LanguageOption(id: "it", title: "意大利语 (Italiano)"),
    LanguageOption(id: "pt", title: "葡萄牙语 (Português)")
]

private let targetLanguageOptions: [LanguageOption] = [
    LanguageOption(id: "zh-Hans", title: "中文 (简体)"),
    LanguageOption(id: "zh-Hant", title: "中文 (繁体)"),
    LanguageOption(id: "en", title: "英语"),
    LanguageOption(id: "ja", title: "日语"),
    LanguageOption(id: "ko", title: "韩语"),
    LanguageOption(id: "fr", title: "法语"),
    LanguageOption(id: "de", title: "德语"),
    LanguageOption(id: "es", title: "西班牙语"),
    LanguageOption(id: "ru", title: "俄语"),
    LanguageOption(id: "it", title: "意大利语"),
    LanguageOption(id: "pt", title: "葡萄牙语")
]

struct SubtitleSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SubtitleSettingsView()
            .environmentObject(ViewModel())
    }
}
