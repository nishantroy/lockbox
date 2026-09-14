# Lockbox Design Gallery

A standalone, fixture-only SwiftUI visual exploration for Phone Lockbox. It has no FamilyControls, Screen Time, App Group, network, or production-source dependencies.

## Generate and build

```sh
xcodegen generate
xcodebuild -project DesignGallery.xcodeproj -scheme DesignGallery \
  -destination 'generic/platform=iOS Simulator' -configuration Debug \
  -derivedDataPath .build-gallery CODE_SIGNING_ALLOWED=NO build
```

The app accepts `-gallery-theme midnight|circadian|lantern` and `-gallery-fixture home|rest|focus` launch arguments for deterministic captures. Theme and fixture are also selectable from Settings → Gallery controls.
