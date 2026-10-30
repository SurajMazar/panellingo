# Building & distribution

## Requirements

- macOS 15+ to run. Building needs Xcode 26 (macOS 26 SDK) for the `TranslationSession(installedSource:target:)` API.
- Swift 6 toolchain (packages use Swift 5 language mode).

## Build

```bash
swift build                              # debug build of everything
swift test                               # 40+ unit & integration tests (real Vision OCR, mocked translator)
PANELLINGO_E2E_OLLAMA_MODEL=qwen3-vl:8b-instruct swift test   # also runs a real local-LLM end-to-end test
scripts/build-app.sh release --universal # dist/PanelLingo.app (arm64 + x86_64), ad-hoc signed
scripts/make-dmg.sh                      # dist/PanelLingo-<version>.dmg
```

`scripts/build-app.sh` builds the app with SwiftPM and assembles the bundle by hand: it copies `Info.plist`, which declares the `.panellingo` package type and the image/PDF/CBZ document types, and the icon. It also includes `panellingo-cli` in `Contents/MacOS`. Set `CODESIGN_IDENTITY` to sign with a Developer ID; the default is ad-hoc (`-`).

`Xcode/PanelLingo.xcodeproj` is generated from `Xcode/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). It builds the same app target and links `PanelLingoKit` from the local package.

## CI / releases

`.github/workflows/ci.yml` runs on `macos-26`:

1. `swift build` and `swift test`
2. generates the Xcode project and runs `xcodebuild` (Release)
3. builds the universal app, smoke-tests the bundled CLI, and packages a DMG
4. uploads the DMG and test log as the `PanelLingo-macOS` artifact
5. on `v*` tags, attaches the DMG to a GitHub Release

## Signing & notarization

CI builds are ad-hoc signed and not notarized, so Gatekeeper asks for right-click › Open the first time. To distribute widely:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh release --universal
scripts/make-dmg.sh
xcrun notarytool submit dist/PanelLingo-*.dmg --keychain-profile <profile> --wait
xcrun stapler staple dist/PanelLingo-*.dmg
```

The app makes outgoing network connections only to the endpoints you configure. If you add the App Sandbox, enable `com.apple.security.network.client`, user-selected file read/write, and bookmark handling for projects.

## Licensing

| Component | License | Notes |
|---|---|---|
| PanelLingo source | MIT | |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | MIT | CBZ/ZIP import and export |
| Apple frameworks (Vision, Translation, Core Text, PDFKit…) | Apple SDK | system frameworks, nothing bundled |
| Fonts | not bundled | presets refer to fonts that ship with macOS (Comic Sans MS, Avenir Next, Chalkboard SE, Helvetica Neue, Impact, SF) |
| AI models | not bundled | downloaded by the user through Ollama, LM Studio or macOS; each model has its own license |
| Sample comic | MIT | drawn procedurally by `SampleComic.swift` |

Do not add copyrighted comic pages to the repository or test fixtures.
