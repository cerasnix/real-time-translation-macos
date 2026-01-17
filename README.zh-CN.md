# Subtitle（macOS 26）

本项目是 [xujizhong/real-time-translation-macos](https://github.com/xujizhong/real-time-translation-macos) 的 fork。感谢原作者提供实现参考。本 fork 进行了大范围重构，主要为适配 macOS 26 新 API，并补充了更多 UI/交互与日志能力。

[English README](README.md)

## 这个 fork 做了什么

- 迁移到 macOS 26 的 SpeechAnalyzer/SpeechTranscriber 实时转写管线
- Overlay 体系重建：纯色/材质/玻璃三种背景，支持行数、字号、透明度调整，并展示最近字幕队列
- 新的设置与日志面板：语言切换、样式参数、自动滚动与日志保存
- TranslationService 统一管理本地翻译会话，语言变化时自动预热/重建

## 功能

- 实时转写系统音频（非麦克风）
- 浮动字幕气泡，始终置顶，可拖动
- 支持本地翻译（Translation.framework，macOS 15+）
- 识别语言与翻译目标可切换
- 本地语音识别强制启用（需离线模型）
- 纯色/材质/玻璃三种字幕背景，支持字体与行数调整
- 快捷键：空格键快速开始（应用聚焦时）、全局 Cmd+Shift+Space 开始/停止
- 日志面板可自动滚动并保存为文本

## 环境要求

- macOS 26（当前工程 Deployment Target）
- Xcode 16+ 或包含 macOS 26 SDK 的版本
- 本地翻译需要 macOS 15+（若不可用则显示原文）

## 构建与运行

1. 使用 Xcode 打开 `subtitle.xcodeproj`。
2. 选择 `subtitle` scheme，并在需要时设置 Signing Team。
3. 编译并运行。首次启动会弹出权限请求：
   - 屏幕录制（用于通过 ScreenCaptureKit 捕获系统音频）
   - 语音识别（用于将音频转写为文本）

无需额外第三方依赖。

## 使用方法

- 选择识别语言（源语言）与翻译目标。
- 点击“开始”以捕获并转写系统音频。
- 屏幕上会出现可拖动、始终置顶的字幕气泡。
- 空格键可快速开始（应用聚焦且空闲时）；点击“停止”结束。
- 全局快捷键：Command+Shift+Space 切换开始/停止。

说明：
- 应用会将所选翻译源（如 `en`、`ja`、`zh-Hans`）映射到合适的 Speech 识别区域设置。
- 在翻译不可用或语言对不受支持时，字幕将回退为原文显示。
- 当前仅捕获所选显示器的系统音频，不包含麦克风输入。

## 代码导航（关键改动）

- `subtitle/ModernCaptureTranscriber.swift`：SpeechAnalyzer/SpeechTranscriber + 音频重采样 + 新的日志/翻译调度
- `subtitle/CaptureTranscriber.swift`：旧管线（SFSpeechRecognizer），用于对比/备用（当前 Deployment Target 为 macOS 26）
- `subtitle/TranslationService.swift`：本地翻译会话管理与缓存
- `subtitle/ContentView.swift`：设置面板、日志面板、保存日志
- `subtitle/OverlayCaptionView.swift`、`subtitle/OverlayWindow.swift`：字幕排版与背景风格
- `subtitle/HotKeyManager.swift`：全局快捷键

## 隐私与权限

- 使用 Apple 原生框架（ScreenCaptureKit、Speech，以及 macOS 15+ 的 Translation），在本地处理。
- 语音识别强制本地执行；若所选语言没有离线模型，将无法开始转写。
- 音频处理由系统框架完成，不会上传到远端。

## 常见问题

- 若提示“语音识别未授权”，请到 系统设置 → 隐私与安全性 → 语音识别 中开启。
- 若无转写结果，请到 系统设置 → 隐私与安全性 → 屏幕录制 中为本应用授权。
- 若提示本地语音识别不支持，请安装对应语言的离线模型或切换到支持的语言。

## 致谢

- 原项目作者 [xujizhong](https://github.com/xujizhong) 提供的实现参考。
- Apple 的 ScreenCaptureKit、Speech 与 Translation 框架。

## 许可协议

本项目使用 MIT 协议开源，详见 `LICENSE` 文件。
