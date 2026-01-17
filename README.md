# Subtitle (macOS 26)

This repository is a fork of [xujizhong/real-time-translation-macos](https://github.com/xujizhong/real-time-translation-macos). Thanks to the original author for the reference implementation. This fork is heavily refactored to target macOS 26 APIs and adds more UI, overlay, and logging features.

[中文说明 (Chinese)](README.zh-CN.md)

## What changed in this fork

- Moved to the macOS 26 SpeechAnalyzer/SpeechTranscriber pipeline 
- Rebuilt the overlay system: solid/material/glass backgrounds, adjustable max lines, font size, and opacity, plus recent caption queue
- New settings and log panel: language switching, style controls, auto-scroll, and log export
- Consolidated on-device translation handling with `TranslationService` and prewarming on language changes

## Features

- Real-time transcription of system audio (not the microphone)
- Floating caption bubble, always on top, draggable
- On-device translation (Translation.framework, macOS 15+)
- Switchable recognition and translation languages
- On-device speech recognition only (requires offline models for the selected locale)
- Solid/material/glass caption backgrounds with adjustable font size and line count
- Shortcuts: Space to start (app focused), global Cmd+Shift+Space toggle
- Log panel with auto-scroll and export

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
- A draggable, always-on-top caption bubble appears on screen.
- Press Space to quickly start when idle (app focused). Click Stop to end.
- Global hotkey: Cmd+Shift+Space toggles start/stop.

Notes:
- The app maps the selected translation source (e.g. `en`, `ja`, `zh-Hans`) to a suitable Speech locale automatically.
- When translation is unavailable or the language pair is unsupported, captions fall back to the original text.
- The app captures system audio from the selected display, not microphone input.

## Code map (key changes)

- `subtitle/ModernCaptureTranscriber.swift`: SpeechAnalyzer/SpeechTranscriber pipeline, audio resampling, log/translation scheduling
- `subtitle/CaptureTranscriber.swift`: Legacy SFSpeechRecognizer pipeline for comparison (fallback if the deployment target is lowered)
- `subtitle/TranslationService.swift`: On-device translation session management
- `subtitle/ContentView.swift`: Settings panel, log panel, log export
- `subtitle/OverlayCaptionView.swift`, `subtitle/OverlayWindow.swift`: Caption layout and background styles
- `subtitle/HotKeyManager.swift`: Global shortcut handling

## Privacy

- Uses Apple frameworks on device (ScreenCaptureKit, Speech, and Translation on macOS 15+).
- Speech recognition is forced to on-device; if the selected locale does not support offline models, transcription will not start.
- Your audio is processed locally by the system frameworks.

## Troubleshooting

- If you see "Speech not authorized", enable it in System Settings -> Privacy & Security -> Speech Recognition.
- If transcription does not start, grant Screen Recording in System Settings -> Privacy & Security -> Screen Recording.
- If you see an on-device recognition error, install the offline model for the selected language or switch to a supported locale.

## Acknowledgements

- Original author: [xujizhong](https://github.com/xujizhong) for the reference implementation.
- Apple ScreenCaptureKit, Speech, and Translation frameworks.

## License

Licensed under the MIT License. See `LICENSE` for details.
