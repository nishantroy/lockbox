# Ambient prototypes

Status: linked into the source-only [build-12 candidate](build12-candidate.md) behind a developer prototype screen. The Live Activity remains best-effort presentation and is not enforcement. Build-12 device QA found that a naturally ended activity stayed visible/stale with the host closed; no automatic-dismissal success is claimed.

## Wind-down notifications

`AmbientKit` is a standalone Swift 6 package for macOS 13 and iOS 17. `WindDownPlanner` accepts a `Calendar`, an explicit `Date`, and a value-only configuration. It returns concrete, non-repeating occurrences with:

- a deterministic identifier in `com.phone-lockbox.ambient.wind-down.*`;
- a concrete bedtime and trigger `Date`;
- `DateComponents` carrying the injected calendar time zone for `UNCalendarNotificationTrigger`;
- only future trigger dates; a trigger that is already past is skipped;
- a maximum of seven planned notifications.

The planner treats bedtime as a civil local time. Foundation resolves skipped/repeated local times according to the injected calendar, and the resulting absolute trigger is what the notification adapter schedules. Cross-midnight lock context can be passed as an `AmbientSessionBoundary`; when a lock is already active, no late heads-up is generated for that session. This is informational planning, not enforcement or a background timer.

`PhoneLockbox/Ambient/WindDownNotificationScheduler.swift` is the native adapter. It:

- requests authorization only when its `requestAuthorization()` method is called (the developer view exposes this behind an explicit button);
- reports not-determined, denied, authorized, provisional, and ephemeral states rather than treating a request as permission;
- replaces and cancels only its own identifier namespace;
- checks the whole app notification queue (64-request system limit) before removing old requests, while retaining our seven-request cap;
- on an add failure, removes partial new requests and attempts to restore the old owned requests, returning an explicit restored/partial outcome for truthful UI;
- rejects duplicates and more than seven requests;
- schedules one-shot calendar triggers with the occurrence's time zone;
- does not silently retry, fall back, or claim that a notification was delivered.

The host should plan and call `replace` on explicit enable/configuration save, and call `disable` on explicit disable. A denied/refused/error result must remain visible as an unavailable wind-down feature.

## Live Activity

`AmbientLiveActivityAttributes` and `AmbientActivityContentState` live in `AmbientKit`. ActivityKit conformance is conditional on `#if canImport(ActivityKit)` and is available to an iOS 17+ host. Content state contains a fixed end and explicit status. It intentionally distinguishes `plannedSession`, `recoveryPending`, `releaseObserved`, `expired`, and `stale`; it has no success/unlocked claim for an unobserved Managed Settings transition.

`PhoneLockbox/Ambient/LiveActivityAdapter.swift` is best-effort presentation only:

- it checks `ActivityAuthorizationInfo.areActivitiesEnabled`;
- it uses `pushType: nil`, so v1 has no APNs dependency;
- `start`, `update`, and `end` are explicit calls and are never policy or timer dependencies;
- at/after a fixed end, a planned or recovery state becomes `stale` rather than implying verified release;
- fixed end is immutable after start: ordinary updates must match the activity attributes and cannot use `releaseObserved`;
- only the specifically named `endAfterObservedRelease(sessionID:)` API can use release-observed copy, and it takes the fixed end from the activity rather than from the caller;
- it reports unavailable, stale/lifetime, and request errors to the host.

There is no supported local OS-scheduled dismissal that preserves an active Dynamic Island until a future fixed end: `ActivityUIDismissalPolicy.after(_:)` is supplied to `Activity.end`, so calling `end` terminalizes the Activity immediately rather than scheduling that call. The monitor therefore launches one detached batch operation over deduplicated exact fences only after enforcement reconciliation returns, and performs one configured/nominal semaphore wait against an absolute 750 ms deadline for the entire batch. This is a bounded best effort, not a guaranteed wall-clock callback bound under preemption, scheduling, or an extension watchdog; extension termination, ActivityKit enumeration/ownership, and device timing can still leave stale presentation. It records only the aggregate no-match, ended-count, timeout, or error in an isolated App Group UserDefaults diagnostic namespace protected by a separate bounded cross-process lock and normalized to the final 16 entries. Foreground/relaunch stale cleanup remains the fallback, and requires device validation.

`Extensions/LockboxLiveActivity/LockboxLiveActivity.swift` is a deliberately small WidgetKit presentation. It shows a fixed end and status, has no ticking countdown, and includes accessibility labels and Dynamic Type-friendly system text. `Info.plist` uses `NSExtensionPointIdentifier = com.apple.widgetkit-extension`. The planned extension bundle identifier is `com.phone-lockbox.app.live-activity`.

## Developer presentation

`PhoneLockbox/Ambient/AmbientPrototypeView.swift` is not connected to the existing `ContentView`. A parent integration can present it from a developer-only route. It starts with wind-down disabled and the Live Activity demo inactive. The buttons are explicit:

- request notification permission;
- enable/disable and replace wind-down requests;
- start, update to recovery-requested, and end a `LIVE ACTIVITY DEMO`.

The demo uses a fake `ambient-demo` session and visibly says it is not a real Phone Lockbox lock. It does not call Screen Time, unlock anything, or establish enforcement. A production hook should provide the real finite session ID/end and observed Managed Settings/session transitions through the adapter APIs.

## Parent integration checklist

1. Add `AmbientKit` as a local Swift package dependency to the app and the host test target; do not copy the package core into `Shared`.
2. Add the two `PhoneLockbox/Ambient` adapter files and the developer view to the iOS app target. Keep permission calls behind user actions.
3. Add the Live Activity source to a new Widget Extension target with bundle ID `com.phone-lockbox.app.live-activity`, the checked-in WidgetKit extension plist, iOS 17 deployment, and `AmbientKit` dependency.
4. Parent-owned project configuration should decide target membership, signing, App Group choices, and any extension capability. This prototype intentionally does not edit those files.
5. Connect real lifecycle/session updates only after the parent runtime supplies a finite committed end and an observed release signal. Do not use notification delivery or Live Activity freshness as enforcement evidence.

## Terra review disposition

- **P1 notification queue/replacement:** fixed in `WindDownNotificationReplacementEngine`. It checks retained non-owned requests against the 64-request system queue before removal, and reports rollback success versus partial replacement after an add failure. The developer view now distinguishes a restored schedule from a partial result.
- **P1 stale Live Activity copy:** fixed by `AmbientLiveActivityPresentation`; the WidgetKit Lock Screen, Dynamic Island and minimal regions derive title/accessibility/compact text from `context.isStale`, so stale context cannot continue to say planned or recovery requested.
- **P2 mutable fixed end/release status:** fixed by validating ordinary updates against `activity.attributes.fixedEnd`, sourcing observed-release end state from those immutable attributes, and rejecting `releaseObserved` through start/update. Pure tests cover both rejected calls.

## Validation performed in this isolated change

- `swift test --package-path AmbientKit` is the focused package test command.
- Tests cover disabled planning, upcoming-only behavior, deterministic IDs, cross-midnight active-session suppression, invalid lead offsets, UTC/DST concrete components, own-namespace replacement/no duplicates, full-queue replacement refusal, nth-add rollback with a fake center, fixed-end stale state, stale widget display mapping, immutable-end/release-status validation, and the eight-hour lifetime classification.
- Native adapters and the WidgetKit extension require the parent iOS target/Xcode SDK; they were intentionally not wired into the existing project in this branch.
