# Product layout v1 contract — 2026-09-12

Owner-approved structural work; visual styling follows collaboratively in a later pass.

## Navigation

Three tabs: **Lockbox**, **People**, **Settings**. Companion-only use must not require Screen Time authorization. Diagnostics and developer controls do not appear in the ordinary Lockbox flow; Developer remains a visible, bottom-most Settings section during testing.

## Lockbox tab

Unlocked hierarchy:

1. Primary **Lock now** action.
2. Tonight card with next automatic start and fixed end.
3. Compact saved-rules and wind-down status.
4. Operational warning only when actionable.

Lock now presents finite choices with **30 minutes preselected**, **1 hour**, and a custom end. Minimum supported duration remains 15 minutes; the exact confirmed absolute end and saved policy are frozen. Conflicts are rejected before policy application. It never silently uses the bedtime end.

The Tonight card also offers **Start bedtime now** whenever a bedtime schedule exists and no lock is active. Confirmation shows the exact next configured morning end. This creates a new bedtime-origin session using the saved bedtime policy, displays **Get some rest**, and does not move or disable future recurrence. It supports an early start, a delayed start, or restarting bedtime after an exact prior session was released; old recovery or trusted-person approvals remain bound to the old session and cannot release the restarted session. The action must never silently create an indefinite lock or shorten an existing one.

Active state replaces the unlocked content. Scheduled origin uses **Get some rest**; manual origin uses **Focus time**. Show fixed end, origin, recovery entry and pending-change notice. No ticking countdown, routine clear control or prominent configuration editor.

## People tab

Explain trusted-person recovery and permit only honest currently available setup. Remote approvals remain unavailable until an authenticated durable relay exists. Pairing/service simulations stay under Developer. No fake working approvals, app-usage sharing, email requirement or Screen Time prompt for companion-only use.

## Settings tab

- Bedtime schedule and restriction selection.
- Recovery and ambient preferences.
- Wind-down derives from the real saved bedtime start; configure only enabled/lead time, not a second bedtime clock.
- Live Activity default off after the build-14 correction. It remains an optional best-effort presentation that users can explicitly enable; Lock-now activity can begin while the app is foregrounded, while scheduled activity is best-effort on later foreground because DeviceActivity extension delivery cannot be represented as guaranteed ActivityKit startup. Reliable host-closed ending requires unprovisioned ActivityKit push infrastructure.
- Visible bottom Developer section containing diagnostics, immediate prototype tools, ambient simulation, developer unlock and emergency reset.

## Presentation boundary

Use native semantic structure and accessibility. The visual direction (palette, type, icon) is the owner-approved [design language](design-language.md). Owner decision 2026-11-06: the app is dark mode only (see [design language](design-language.md)). Copy and colour still support both nighttime rest and daytime focus.

## Delivery

Separate runtime/manual-duration work from SwiftUI navigation/layout ownership. Review, test and build before device installation. Do not silently install or modify schedules.
