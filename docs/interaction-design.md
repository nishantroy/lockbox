# Phone Lockbox — interaction design

Status: target behavior specification, not a description of the current Form-based prototype. R2/R3 session, recovery, immutable active-rule and bounded Lock now behavior is integrated in the current source candidate; focused device acceptance remains open. See [roadmap](roadmap.md) and [QA evidence](status-and-qa.md). Visual polish follows reliability.

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

### 5. Future optional accountability (after production relay)

This does not appear in the bedtime MVP. Once the authenticated, durable trusted-person relay is production-ready, the owner can opt in and select accepted trusted people one at a time. Sender consent and recipient consent are explicit and revocable. Per person, the owner separately chooses approval of early end, receipt of exact-session requests, early-end notices, weekly shared summaries and (optionally) a mutual pact. An approval is one-use, signed and bound to the exact session; the initial release rule is one-of-N first valid approval. A friend cannot start or extend a lock, change rules, or see selections, usage or task steps. A recipient can opt out, and the owner can cancel a pending relationship or delivery. Multiple recipients remain independent. A mutual pact is two one-way relationships, so neither person controls or inspects the other's lock.

Use calm copy such as “Your Lockbox session ended early.” Never call an early end a failure or shame the owner. Natural end, recovery, trusted approval, authorization loss/integrity warning, and developer/emergency cleanup have distinct statuses. Event recording occurs locally before ordinary release clears policy and queues for offline delivery; emergency access never waits for the network. The server inbox/fetch is authoritative, while APNs/text are wake/reminder hints only.

Notification previews are generic by default, and quiet hours defer presentation rather than bypassing them. The default payload includes no app selections, app/site usage, messages, raw schedules, or task details. An optional weekly summary shows only planned, naturally completed, ended early, and unavailable/integrity-unknown counts/statuses—no streaks, scores, rankings, or shame. Delivery cancellation/late delivery, retention/deletion, reinstall/clock limits, and recipient opt-out are specified in [accountability design](accountability-design.md). Do not expose this flow while only the in-memory core or a relay simulation exists.

### 6. Future local insights, schedules and quick actions

These surfaces follow the [roadmap](roadmap.md) after R5/R6 and do not weaken the bedtime lifecycle:

- **Screen Time insights:** first run a DeviceActivityReport feasibility spike. Today/7-day top apps and categories, inside/outside protected time, and a by-hour/day heatmap are shown only when supported. Keep data local; do not promise raw report export, pickups or notifications unless Apple's APIs provide them.
- **Safety assistant:** offer an essentials checklist, strict allow-only warnings and a browser/system/critical-app test flow. It is a review aid, not an emergency guarantee.
- **Weekend then named rules:** begin with bounded weekday/weekend rules. Each rule has days/time/policy; preview and reject overlaps, freeze active occurrences, and do not introduce vacation/skip exceptions. Later named times of day require a separate conflict contract.
- **Personal weekly review:** keep it local and distinct from shared accountability. Show protected time/completion/ended-early/unknown counts and supported usage patterns without streaks, scores or shame.
- **Shortcuts/App Intents:** expose only finite 30-minute, one-hour or named-rule starts, status and recovery entry. Validate confirmation, parameters and authorization truthfully; never offer indefinite locks or an instant recovery bypass.
- **Task-based unlock experiments:** opt-in and disableable outside active commitments. Freeze task, policy, cutoff and session at start; use an immutable finite OS cutoff, delayed confirmation and optional exact-session friend approval. Never gate critical essentials or allow a task to extend a session. Initial candidates (steps, a private espresso photo ritual and bounded math) are feasibility experiments, not medical, anti-cheat or proof claims; provide accessible alternatives.

### 7. Authorization or enforcement problem

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

- MVP: one repeating daily window in local civil time, usually crossing midnight. The first approved expansion is a bounded weekday/weekend pair; general schedule exceptions are not part of the design.
- Store actual start/end instants for each active occurrence. Routine settings edits do not recompute its end.
- Reject equal start/end, unsupported intervals, and invalid selections with actionable messages. Derive technical bounds from current APIs during the spike.
- Future occurrences follow the current local time zone. An already active session retains its resolved end instant; test whether OS callbacks can support this consistently.
- For DST, the provisional rule is the next valid time for a skipped boundary and the first occurrence for a repeated boundary. Test and document actual scheduler behavior before promising parity.
- Manual sessions use an explicit confirmed future end. Repeated “lock now” cannot shorten an active session. Overlaps must remain restricted until all applicable unreleased sessions end; the UI displays that effective end.
- Relaxing essentials, shortening an active window, changing recovery friction, or disabling scheduling cannot provide an immediate in-app bypass.
- Pending edits activate after the effective current lock ends, including deliberate recovery. Preview whether a newly configured window would be active then; do not silently start a replacement lock immediately after recovery. Weekend and later named-rule conflicts are rejected initially rather than resolved by undocumented precedence.
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
