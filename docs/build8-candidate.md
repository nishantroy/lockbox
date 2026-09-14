# Build 8 — in-app design gallery candidate

Build identity `0.1 (8)`.

Adds a static, developer-only visual gallery at **Settings → Developer → Open design gallery** inside the existing Phone Lockbox app. The gallery presents Midnight Sanctuary, Circadian Calm and Soft Lantern across unlocked Home, Get some rest and Focus time fixtures. It opens full-screen, has an explicit Done control and states that it does not change restrictions. It has no coordinator, Screen Time, notification, ActivityKit, storage or network integration.

The Soft Lantern light palette was corrected after independent review; affected contrast ratios are 5.97:1–6.96:1. The final independent review found no P0/P1 issues and gave an install-ready source/build verdict.

Exact merged-tree validation: 84 root tests passed and the signed generic-device build succeeded with bundle version 8. Build 8 was installed on the paired iPhone on 2026-09-13 at 23:34 local after one transient wireless connection reset. Automatic launch was denied because the phone was locked; installation succeeded. Physical-device presentation remains owner QA.
