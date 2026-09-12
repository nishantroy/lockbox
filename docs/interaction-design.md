# Phone Lockbox — interaction design

Status: target behavior specification, not a description of the current Form-based prototype. Recovery UI, immutable active rules and bounded Lock now are not integrated yet. See [roadmap](roadmap.md) and [QA evidence](status-and-qa.md). Visual polish follows reliability.

Related: [product plan](product-plan.md), [technical plan](technical-plan.md).

## Design principles

- Make the current restriction and its end understandable at a glance.
- Put configuration outside the nightly experience.
- Prefer fewer choices during a lock, without hiding safety or recovery information.
- Do not keep the user watching a countdown or completing an engaging challenge.
- State platform limits plainly; distinguish desired policy from observed authorization and last successful policy application.
- Use text and accessible system controls; never communicate status only by color.

## Main screens

### 1. Setup

1. Explain: “Keep essentials available. Restrict everything else we can during bedtime.”
2. Explain owner bypasses, system exceptions, and the difference between blocking and silencing notifications.
3. Request individual Screen Time authorization. Denial leaves setup incomplete; offer an explanation and retry, not an apparently armed schedule.
4. Configure start and end times through native time controls. Illustrative times are not requirements; explicitly confirm values before enabling.
5. Select essential apps using supported system selection UI. Avoid a custom installed-app directory, which iOS does not generally provide.
6. Review recovery friction and active-session edit rules.
7. Run a short, explicitly bounded test restriction and verify necessary functions before enabling overnight use. Exact test duration depends on supported scheduling constraints established in the spike; do not fake a reliable release using a foreground timer.
8. Enable the schedule only after review. If already inside today's window, explicitly offer starting now or waiting until the next occurrence.

Selecting messages, email, music, or a browser is the user's decision. Briefly explain that an essential can also become a distraction; do not impose developer-chosen exceptions silently.

Optional follow-up guidance: Sleep Focus, badges, Home Screen layout, and an existing minimalist launcher. None are prerequisites to blocking.

### 2. Unlocked home

```text
Phone Lockbox

Next lock: tonight, 10:00 p.m.
Opens tomorrow at 7:00 a.m.

[ Lock now ]

Schedule                 10 p.m.–7 a.m.
Essentials               Review selection
Recovery                 15-minute wait
```

Times are illustrative. “Lock now” opens confirmation with the actual start/end dates and allowed essentials. If a manual lock overlaps a scheduled window, the preview shows the effective end; do not silently shorten an existing restriction or surprise the user with an unannounced extension.

### 3. Locked home

```text
Phone closed for tonight

Scheduled to open at 7:00 a.m.
Your selected essentials remain available.

View active rules
Changes for after this lock
Recovery options
```

Show this normal state only when authorization and policy application are not known to have failed. It is not proof that every possible entry point has been tested or that other apps' restrictions are absent.

Settings are still reachable. A relaxation is labelled with its future effective boundary before saving; never silently pretend it applied immediately. Disabling the recurring schedule during a lock affects future occurrences, not the current session.

### 4. Recovery

First screen explains that this ends the current session and does not disable future nights. Present noninteractive emergency-access guidance appropriate to the tested device behavior; do not force emergency calling through our recovery flow.

```text
Need to end tonight's lock?

Recovery requires a 15-minute wait.
You can put your phone away while you wait.

[ Request recovery ]
[ Keep lock active ]
```

After requesting:

```text
Recovery requested

You can confirm release after 11:42 p.m.
Apps remain restricted until you confirm
or the scheduled lock ends.

[ Cancel request ]
```

At eligibility, expose “End this lock” with confirmation. No automatic unlock at eligibility, no per-second countdown, and no mandatory notification. Check eligibility again when confirming, not just when rendering the button.

- App termination does not reset or accelerate a request.
- Repeated taps do not move eligibility earlier.
- Cancelling and requesting again starts a new wait.
- The normal morning end wins if it comes first.
- Completion marks only the active occurrence released so reconciliation does not immediately reblock it.
- The 15-minute duration is provisional and not an in-lock adjustable setting.

### 5. Authorization or enforcement problem

Examples:

- “Screen Time access is off. This app cannot currently enforce your rules.”
- “The schedule could not be registered. Automatic blocking is not confirmed.”
- “Restrictions could not be updated. They may still be active.”

Offer retry, setup guidance, or the tested cleanup procedure as appropriate. A failed attempt to clear shields must not be shown as a successful unlock. Avoid assuming that loss of callbacks can be detected continuously in the background.

## State model

Keep policy/session state separate from authorization and operational health. “Recovery requested” and “authorization missing” can coexist; one label must not erase the other.

### Session lifecycle

| State | Trigger | Result |
| --- | --- | --- |
| No active session | Confirmed scheduled start or manual start | Persist bounded session and apply policy, recording outcome. |
| Active | Recovery request | Remain restricted; persist eligibility time tied to session ID. |
| Recovery pending | Eligible, explicit confirmation | Mark occurrence released and clear this app's active policy; surface failures. |
| Active or recovery pending | Scheduled end | Expire session, cancel its recovery, clear its policy, and activate eligible pending configuration. |
| Active | Relaxing edit | Queue for after the current session; do not alter the current baseline. |
| Active | Strictly stronger supported edit | Apply immediately if policy comparison proves it is stronger; otherwise queue conservatively. |
| Released occurrence | Duplicate start callback or app launch | Stay released for that occurrence; keep future schedule enabled. |
| Any | Permission loss detected | Show unavailable authorization; preserve configuration and do not claim enforcement. |

Authorization restoration requires a clear explanation that an unexpired session may resume, unless that occurrence was already recovered. Do not silently extend its original end time. Setup and error overlays are independent of the lifecycle.

## Schedule and edit semantics

- MVP: one repeating daily window in local civil time, usually crossing midnight.
- Store actual start/end instants for each active occurrence. Routine settings edits do not recompute its end.
- Reject equal start/end, unsupported intervals, and invalid selections with actionable messages. Derive technical bounds from current APIs during the spike.
- Future occurrences follow the current local time zone. An already active session retains its resolved end instant; test whether OS callbacks can support this consistently.
- For DST, the provisional rule is the next valid time for a skipped boundary and the first occurrence for a repeated boundary. Test and document actual scheduler behavior before promising parity.
- Manual sessions use an explicit confirmed future end. Repeated “lock now” cannot shorten an active session. Overlaps must remain restricted until all applicable unreleased sessions end; the UI displays that effective end.
- Relaxing essentials, shortening an active window, changing recovery friction, or disabling scheduling cannot provide an immediate in-app bypass.
- Pending edits activate after the effective current lock ends, including deliberate recovery. Preview whether a newly configured window would be active then; do not silently start a replacement lock immediately after recovery.
- Preserve release identity for the recovered original occurrence even if the schedule is edited during it. Future schedule edits cannot resurrect that occurrence. The implementation must specify activation boundaries and test this case.

These clock, overlap, and edit rules are desired semantics, not evidence of platform feasibility. Revise explicitly if device experiments reveal unsupported behavior.

## System shield

The shield is a restricted extension surface, not another full SwiftUI screen. Plan for short text, a clear reason, and an end time only when extension data supports it.

Example: “Unavailable during bedtime. Scheduled to open at 7:00 a.m.”

Do not promise a text-entry form, arbitrary navigation into the main app, live countdown, or a recovery workflow inside the shield. Validate supported buttons/actions first. Recovery can be entered by opening the main app normally.

## Visual and accessibility direction

- System typography, strong contrast, restrained color, generous spacing.
- Support Dynamic Type and VoiceOver for time pickers, selection summaries, pending changes, and recovery.
- Avoid meaning conveyed only by app icons, colors, animation, or haptics.
- No mandatory onboarding animation or repeated nightly reminders.
- Defer branding, custom illustration, widget layout, and typography experiments.
