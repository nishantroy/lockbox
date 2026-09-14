# Lockbox Design Gallery

A standalone, fixture-only SwiftUI visual exploration for Phone Lockbox. It has no FamilyControls, Screen Time, App Group, network, or production-source dependencies.

## Generate and build

```sh
xcodegen generate
xcodebuild -project DesignGallery.xcodeproj -scheme DesignGallery \
  -destination 'generic/platform=iOS Simulator' -configuration Debug \
  -derivedDataPath .build-gallery CODE_SIGNING_ALLOWED=NO build
```

The app accepts `-gallery-theme midnight|circadian|lantern|midnightOriginal|midnightContrast|adaptivePreview`, `-gallery-fixture home|rest|focus`, and `-gallery-appearance dark|light` launch arguments for deterministic captures. Theme and fixture are also selectable from Settings → Gallery controls; Appearance is shown for the Adaptive Preview. Round 1 references remain preserved alongside the three Round 2 choices. Production preference is always dark; Adaptive Preview is gallery-only.
