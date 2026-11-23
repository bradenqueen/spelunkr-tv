# Repository Guidelines

## Project Structure

`SpelunkrTV/` contains the SwiftUI tvOS app. `SpelunkrTVApp.swift` is the entry point, and `Views/` contains the channel guide, player screen, and bump cards. `BroadcastStore.swift` loads the lineup and manifests, `ScheduleEngine.swift` bridges the schedule engine through JavaScriptCore, and `TVPlayer.swift` handles AVPlayer playback. Put app icons, Top Shelf images, and colors in `SpelunkrTV/Assets.xcassets`. `tools/` holds the engine generator and its JavaScript bridge. `docs/` holds project documentation and README artwork.

## Build and Run

Develop and test against tvOS 27. Use Xcode with the tvOS 27 SDK and Node.js 18 or newer. The Xcode project currently declares a minimum deployment version of tvOS 17.0.

- `node tools/update-engine.mjs` downloads and smoke-tests the upstream schedule engine, then writes `SpelunkrTV/Engine/spelunkr-engine.js.txt`. Run it before building and when the upstream schedule format changes. Keep the generated engine out of Git.
- `open SpelunkrTV.xcodeproj` opens the project. Select the `SpelunkrTV` scheme and a tvOS 27 simulator or Apple TV running tvOS 27, then press Command-R to build and run. Select your signing team for a physical device.
- `xcodebuild -project SpelunkrTV.xcodeproj -scheme SpelunkrTV -destination 'generic/platform=tvOS Simulator' build` compiles the simulator build from the command line.

## Coding Style

Use four spaces in Swift and two in `tools/` JavaScript. Use `UpperCamelCase` for Swift types and `lowerCamelCase` for properties and functions. Name Swift files after their primary type, such as `GuideView.swift`, and use kebab-case for tool scripts. Match surrounding formatting.

## Testing

The project has no dedicated test target or coverage threshold. The engine generator runs live-data smoke tests for scheduling and overlay playlists. For app changes, verify the affected flows on a simulator or Apple TV. For playback changes, check guide-to-player navigation, channel switching, and return-to-guide focus. Note the device or simulator and tvOS version used.

## Commits and Pull Requests

Use short, action-oriented commit subjects such as `Skip frame-rate matching where AVDisplayManager is unavailable`. Describe the change and verification in the PR, link related issues when applicable, and include screenshots or a short recording for visible UI changes.
