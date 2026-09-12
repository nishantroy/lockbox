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

Active state replaces the unlocked content. Scheduled origin uses **Get some rest**; manual origin uses **Focus time**. Show fixed end, origin, recovery entry and pending-change notice. No ticking countdown, routine clear control or prominent configuration editor.

## People tab

Explain trusted-person recovery and permit only honest currently available setup. Remote approvals remain unavailable until an authenticated durable relay exists. Pairing/service simulations stay under Developer. No fake working approvals, app-usage sharing, email requirement or Screen Time prompt for companion-only use.

## Settings tab

- Bedtime schedule and restriction selection.
- Recovery and ambient preferences.
- Wind-down derives from the real saved bedtime start; configure only enabled/lead time, not a second bedtime clock.
- Live Activity default on after explanation. Lock-now activity can begin while the app is foregrounded; scheduled activity is best-effort on later foreground because DeviceActivity extension delivery cannot be represented as guaranteed ActivityKit startup.
- Visible bottom Developer section containing diagnostics, immediate prototype tools, ambient simulation, developer unlock and emergency reset.

## Presentation boundary

Use native semantic structure and accessibility, but no final palette, illustration, typography system or decorative visual direction yet. Preserve system light/dark behavior. Layout language supports both nighttime rest and daytime focus; do not make the entire product intrinsically nocturnal.

## Delivery

Separate runtime/manual-duration work from SwiftUI navigation/layout ownership. Review, test and build before device installation. Do not silently install or modify schedules.
