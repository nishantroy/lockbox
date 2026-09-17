# Build 15 — reviewed local feature foundations

Build identity `0.1 (15)`.

This candidate carries the build-14 custom-end and honest default-off Live Activity corrections forward and adds four independently reviewed source integrations:

- Safety Assistant: a privacy-minimal local checklist in Settings that cannot mutate policy or guarantee emergency access.
- Quick Actions: four navigation/confirmation App Intents for 30-minute focus, one-hour focus, status and recovery. Routes cannot start enforcement or release recovery directly. Their bounded App Group queue uses canonical URLs, descriptor-bound reads, token-bound claims, lease retries and explicit terminal handling.
- Weekday/weekend scheduling pure core: stable frozen occurrences and bounded persistence contracts, deliberately disconnected from App Group migration, DeviceActivity registration and enforcement.
- Task-unlock pure core: finite exact-session commitment and cutoff rules, deliberately disconnected from providers, UI, friend authority and enforcement.

Insights is not included because the report extension lacks its Family Controls provisioning profile. Friend-permission work is not included because no independently trusted monotonic checkpoint backend, hosted relay, APNs path or enforcement consumer is approved.

Combined source validation before the version increment passed 150 SwiftPM tests, 30 AmbientKit tests, 51 iOS simulator tests with one expected Data Protection metadata skip, signed generic-device build and strict codesign verification, XcodeGen determinism, and the gallery contrast audit. The version-15 build then succeeded for the paired iPhone, passed strict codesign verification, and reported bundle identity `0.1 (15)`.

Build 15 installed and launched successfully on the paired iPhone 15 Pro on 2026-09-17. No schedule was changed. Device QA must distinguish build-15 feature delivery checks from the still-open custom-end/Live Activity migration evidence and the wider R4 reliability gate. Installation and launch are not a pass for Siri/Shortcuts, Data Protection, weekend/task runtime behavior, automatic release or accessibility.
