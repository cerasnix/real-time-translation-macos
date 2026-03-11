# Subtitle (macOS 26)

This repository is a fork of [xujizhong/real-time-translation-macos](https://github.com/xujizhong/real-time-translation-macos). Thanks to the original author for the reference implementation. This fork is heavily refactored around the macOS 26 SpeechAnalyzer pipeline and now focuses on a more native macOS workbench UI, overlay preview parity, richer logs, and export tooling.

[中文说明 (Chinese)](README.zh-CN.md)

## What changed in this fork

- Moved to the macOS 26 SpeechAnalyzer/SpeechTranscriber pipeline
- Rebuilt the overlay system: solid/material/liquid-glass backgrounds, adjustable line count, font size, tint strength, and recent caption queue
- Reworked the main window into a macOS-style sidebar + single-page workbench with live preview and activity log
- Consolidated on-device translation handling with `TranslationService`, language-pair session caching, and prewarming on language changes
- Added grouped log cards with timestamps, internal scrolling, and text/SRT export

## Features

- Real-time transcription of system audio (not the microphone)
- Floating caption bubble, always on top, draggable, and resizable
- On-device translation (Translation.framework, macOS 15+)
- Switchable recognition and translation languages
- On-device speech recognition only (requires offline models for the selected locale)
- Solid/material/liquid-glass caption backgrounds with adjustable font size, line count, and tint strength
- Live preview that follows the current floating overlay size and aspect ratio
- Shortcuts: Space to start (app focused), global Cmd+Shift+Space toggle
- Activity log with grouped subtitle cards, timestamps, auto-scroll, and export
- Export subtitle history as plain text or SRT

## Requirements

- macOS 26 (current deployment target)
- Xcode 16+ or any version that ships the macOS 26 SDK
- On-device translation requires macOS 15+ (falls back to source text when unavailable)

## Build & Run

1. Open `subtitle.xcodeproj` in Xcode.
2. Select the `subtitle` scheme and set your Signing Team if needed.
3. Build and Run. On first launch macOS will prompt for:
   - Screen Recording permission (for capturing system audio via ScreenCaptureKit)
   - Speech Recognition permission (for transcribing audio)

No external dependencies are required.

## Usage

- Choose the recognition language (source) and the translation target.
- Click Start to begin capturing and transcribing system audio.
- A draggable, always-on-top caption bubble appears on screen. You can resize it directly with the mouse.
- Press Space to quickly start when idle (app focused). Click Stop to end.
- Global hotkey: Cmd+Shift+Space toggles start/stop.
- The right-side activity log keeps recent caption pairs grouped by day and timestamped by entry.
- Use the Export menu in the log panel or the app menu to save plain text logs or SRT subtitles.

Notes:
- The app maps the selected translation source (e.g. `en`, `ja`, `zh-Hans`) to a suitable Speech locale automatically.
- When translation is unavailable or the language pair is unsupported, captions fall back to the original text.
- The app captures system audio from the selected display, not microphone input.
- Current SRT export uses session-relative timestamps derived from each finalized caption entry, not absolute media timeline timecodes.

## Code map (key changes)

- `subtitle/ModernCaptureTranscriber.swift`: SpeechAnalyzer/SpeechTranscriber pipeline, audio resampling, log/final-translation scheduling
- `subtitle/CaptureTranscriber.swift`: Legacy SFSpeechRecognizer pipeline for comparison and fallback
- `subtitle/TranslationService.swift`: On-device translation session management, sentence splitting, language-pair caching
- `subtitle/ContentView.swift`: Sidebar settings, live preview, grouped log panel, and export UI
- `subtitle/NativeGlassSurface.swift`: AppKit-backed Liquid Glass host view for custom caption surfaces
- `subtitle/OverlayCaptionView.swift`, `subtitle/OverlayWindow.swift`: Caption layout, window sizing, and floating overlay presentation
- `subtitle/HotKeyManager.swift`: Global shortcut handling

## Privacy

- Uses Apple frameworks on device (ScreenCaptureKit, Speech, and Translation on macOS 15+).
- Speech recognition is forced to on-device; if the selected locale does not support offline models, transcription will not start.
- Your audio is processed locally by the system frameworks.

## Troubleshooting

- If you see "Speech not authorized", enable it in System Settings -> Privacy & Security -> Speech Recognition.
- If transcription does not start, grant Screen Recording in System Settings -> Privacy & Security -> Screen Recording.
- If you see an on-device recognition error, install the offline model for the selected language or switch to a supported locale.
- If the floating overlay looks different from the live preview, make sure you are launching the freshly built app from `DerivedData/Build/Products/Release/subtitle.app` rather than an older copy in `/Applications`.

## Acknowledgements

- Original author: [xujizhong](https://github.com/xujizhong) for the reference implementation.
- Apple ScreenCaptureKit, Speech, and Translation frameworks.

## License

Licensed under the MIT License. See `LICENSE` for details.
