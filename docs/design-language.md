# Phone Lockbox design language v1 — "Quiet Night"

Status: **owner-approved 2026-11-06** (dark mode only, lavender primary, icon v1 approved). App icon v1 is implemented from it (`design/icon/render-app-icon.swift`). The UX redesign (section 6) is in progress. It builds on the owner-selected Midnight Original direction ([design polish](design-polish.md)) and keeps the approved structure ([layout v1](layout-v1-contract.md), [interaction design](interaction-design.md)).

Evidence base: the SwiftUI source (`DesignSystem/LockboxDesignSystem.swift`, `LockboxTabView`, `PeopleView`, `SettingsView`, `RecoveryView`, `ManualLockSheet`) and the previous icon. No new screenshots were taken (owner rule 2026-11-06: no simulator runs without the owner saying so). Before the redesign starts, re-check against the owner's screenshots or an owner-approved UI run.

## 1. Evaluation of the current design

### What works (keep)

- **One small, coherent token set** (`LockboxTheme`): a deep canvas, navy surfaces, lavender, and blue. Almost all screens use it.
- **Calm, owner-approved Midnight palette.** It suits bedtime, and the contrast is good (secondary text `#ADB3D1` on surface `#131830` is about 8:1).
- **Rest and focus have their own colours** (lavender for bedtime, blue for focus). That's a good idea; it just isn't used consistently (see below).
- **Accessibility basics are in place:** system text styles (so Dynamic Type works), 44 pt minimum controls, header traits, accessibility hints, and decorative icons hidden from VoiceOver.
- **Honest, non-shaming copy rules:** no countdowns, no streaks, "ended early" instead of "failed".
- **One custom button style** with clear primary, secondary and destructive emphasis, and press feedback.

### What doesn't (fix)

1. **The headline is a tagline, not the current state.** Setup and the unlocked home both open with "A calmer phone, when you need it". The most important fact (am I locked, and until when?) sits lower on the page. The active lock uses mood headlines ("Keep a clear lane") instead of "Locked until 7:00".
2. **Lavender means everything.** It is the accent, the rest state, every section label, the tint, and the primary button, so it no longer signals anything. Blue focus only appears inside an active focus lock.
3. **Everything is a card with an uppercase lavender label.** Every block has the same visual weight, so hierarchy comes only from order. Settings-like content (rhythm, wind-down, people lists) would read better as plain grouped rows.
4. **Too much small explanatory text.** About 90 `.footnote` uses. Many are policy-precise but legalistic ("The end is finite and is checked again when you confirm…", "Unsaved settings edits are not included. The saved policy is frozen…"). They add reading during the moments when the user wants fewest steps.
5. **Warning colour is ad hoc.** System `.orange` and `.red` are used inline, not as tokens. There is no calm "needs attention" colour, so warnings either shout (red) or drift (orange).
6. **Times are verbose and inconsistent.** "Nov 6, 2026 at 10:00 PM" appears in the Tonight card, and the bedtime confirmation spells out a full date and time to the second. A time alone, or "Tomorrow 7:00 AM", reads faster.
7. **The previous icon was a thin outlined phone with a moon.** It read as a "night mode / sleep tracker" app, said nothing about locking, its thin strokes and star dots disappear at home-screen size, and it left large empty margins.
8. **Light/dark is unresolved.** Production forces dark mode (`preferredColorScheme(.dark)`), which the owner chose. The layout contract says not to make the product purely nocturnal, and Focus time is a daytime feature. This needs an owner decision (see §4).
9. **Prototype and developer surfaces leak into ordinary screens.** Examples are the People "Prototype" card and developer toggles. That's fine for testing, but the redesign needs to define how they look so they can't be mistaken for real features.

## 2. Principles

1. **State first.** Every screen opens with what's true now, in plain words, with the time as the hero: "Open · Bedtime at 10:00 PM" or "Locked until 7:00 AM".
2. **One colour, one job.** Colour carries state, not decoration: lavender for rest, blue for focus, amber for "needs attention", red only for destructive actions. Section labels are neutral.
3. **Fewer containers.** Cards are for things (tonight's lock, the active session, a person). Lists of settings or values use grouped rows.
4. **One sentence, then details on request.** At most one line of help under a control. Precise policy text moves behind an info disclosure or onto the confirmation screen where it actually matters.
5. **Calm, not cute.** No countdowns, streaks, confetti or shame. Motion is minimal and respects Reduce Motion.
6. **Honest by construction.** Never use colour alone to show state, never hide a safety route, and always label prototypes.

## 3. Foundations (tokens)

### Colour — Midnight (current production, refined)

| Token | Hex | Use |
|---|---|---|
| `canvas` | `#090C1C` | Page background |
| `surface` | `#131830` | Cards, grouped rows |
| `surfaceRaised` | `#1B203D` | Sheets, pressed rows, the active-session hero |
| `hairline` | `#404773` at 60% | Card borders, dividers |
| `textPrimary` | `#F2F0FF` | Titles, values |
| `textSecondary` | `#ADB3D1` | Help text, labels (was lavender for section labels; change to this) |
| `rest` | `#C2B0FA` | Bedtime state, primary action while unlocked |
| `focus` | `#75C2FA` | Focus-lock state; primary action inside focus |
| `attention` | `#F5B661` (new) | Needs a decision, or something isn't working (replaces inline `.orange`) |
| `destructive` | system red | Destructive actions only |
| `onAccent` | `#140E29` | Text on rest/focus fills |

- **State tint rule:** the active screen's hero and primary button take the session's colour (rest or focus). When unlocked, primary is `rest`.
- **Contrast:** check every text pair at ≥ 4.5:1, and ≥ 3:1 for large numerals and icons.

### Type — SF Pro (system), with SF Pro Rounded for time

- **Time hero:** `.system(.largeTitle, design: .rounded).weight(.semibold)` with `monospacedDigit()`, e.g. "7:00 AM". Rounded softens the numbers; monospaced digits keep times from jumping as they change.
- **Page title:** `.title2.weight(.semibold)`. It names the state, not a slogan.
- **Body:** `.body`. **Help:** `.subheadline` in `textSecondary`. Reserve `.footnote` for legal or prototype notes.
- **Section labels:** `.footnote.weight(.semibold)` in `textSecondary`, sentence case. Drop the tracked uppercase lavender.
- No custom fonts: system fonts get Dynamic Type, accessibility and localisation for free.

### Shape, space, elevation

- Continuous corners: 20 for cards and sheets, 12 for controls, capsule for badges.
- **Spacing scale:** 4, 8, 12, 16, 20, 24, 32. Page gutter 20; space between cards 16; padding inside cards 16–18.
- **Elevation:** no shadows in-app. Depth comes from `surface` and `surfaceRaised` plus a hairline.
- **Motif:** the padlock with a crescent keyhole (the icon). Use it sparingly: the setup hero, the active-lock hero, and the shield.

### Iconography

- SF Symbols only, `.semibold`, at text size. Fixed symbol per concept:
  - `moon.fill` → bedtime;
  - `scope` → focus (the current `sparkles` reads as magic or AI);
  - `lock.fill` → locked;
  - `person.2` → people;
  - `exclamationmark.circle` → attention.
- Icons go with text; they never carry meaning on their own.

### Motion

- State changes cross-fade in 0.2–0.25 s with ease-out. Press feedback stays as is.
- No looping or ambient animation. Under Reduce Motion, changes are instant.

## 4. Owner decisions (2026-11-06)

1. **Dark mode only.** Production stays always-dark (`preferredColorScheme(.dark)`). This supersedes the layout contract's "preserve system light/dark" line. No light palette.
2. **Lavender (`rest`) is the primary action colour** while unlocked.
3. **Icon v1 approved.**
4. **Session colours confirmed after build 25** (owner hands-on): blue card during focus, lavender during bedtime.
5. **Lock now becomes a large round button at the centre of the open screen** (owner idea, agent decision 2026-11-06; see §6.2a). It fits the goal: while the phone is open, Lock now is the one deliberate action (bedtime runs by itself), so it should be the clear centre of the screen. Constraints that keep it calm and honest:
   - the state still comes first: "Open" and "Bedtime at …" sit above the circle;
   - tapping opens the existing duration sheet, so there is no one-tap or accidental lock and no new step;
   - the circle is a button, not a timer: no progress ring, countdown or looping glow, before or during a lock;
   - the active lock keeps the approved full-width session-colour card;
   - information stacks above and below the circle rather than orbiting it, so it stays readable with large text.

6. **One-tap Lock now and a shared circle (owner feedback on build 26, 2026-11-06).** The extra tap to pick a duration added friction, and the move from the circle to the blue card felt incoherent. Decided (see §6.2b):
   - Duration chips sit on the Open screen: **30 min** (preselected), **1 hour**, and **Until…** (custom time).
   - The circle shows the exact end ("until 11:46 PM") and locks on one tap. The end shown on the button is the confirmation. This supersedes "Lock now opens confirmation" in layout v1 and interaction design for the in-app button. Quick actions and Shortcuts are unchanged.
   - The active lock reuses the same composition: "Locked" replaces "Open", and the circle stays in place in the session colour with the end time as its hero. The full-width card is retired.

## 5. App icon v1

- **Concept:** a padlock whose keyhole is a crescent moon. It says "lock" and "night" at a glance, and it stays legible at 60 px because it uses bold filled shapes with no strokes or star dots.
- **Construction:**
  - background is a vertical midnight gradient (`#1D2150` to `#0B0E22`) with a soft lavender glow behind the lock;
  - the lock is a lavender gradient (`#D9CCFF` to `#A996F2`);
  - the keyhole is navy (`#12153A`);
  - a single 1024 px image with no transparency.
- **Source:** `design/icon/render-app-icon.swift` (CoreGraphics, reproducible). The installed asset is `PhoneLockbox/Assets.xcassets/AppIcon.appiconset/AppIcon.png`.
- **Rejected concepts:**
  - the crescent as the shackle read as a handbag;
  - a lidded box with a clasp read as a camera.

## 6. UX redesign — proposed scope (after sign-off)

Order of work: tokens first, then the Lockbox tab, then the active lock and recovery, then People, then Settings. Behaviour and structure stay as approved; this is a visual and copy pass.

1. **Tokens:** add `attention`, make section labels neutral, add a time-hero style, and replace the inline `.orange` and `.red`.
2. **Lockbox, unlocked:**
   - Hero: "Open" plus "Bedtime at 10:00 PM" (or "No bedtime set").
   - Primary: Lock now.
   - Tonight: a compact row with Start bedtime now.
   - Rhythm and wind-down: grouped rows instead of a card.
2a. **Lock now hero (D1b):**
   - A centred circle, about 184 pt (scales with Dynamic Type and never exceeds about 60% of the screen width), filled with `rest`.
   - Inside: `lock.fill` and the text "Lock now" in `onAccent`. A soft static lavender halo echoes the icon.
   - Press feedback: a slight scale-down, skipped under Reduce Motion.
   - Under it: one line, "30 minutes, 1 hour, or until a time you choose."
   - When Screen Time access is off, it is dimmed and says why, with one line under it pointing to Recovery or Settings.
   - At accessibility text sizes it falls back to the full-width primary button.
   - Below it: Tonight and Your rhythm, as now.
2b. **One-tap lock and shared circle (D1c):**
   - **Open:**
     - title "Open" and the bedtime line;
     - chips (30 min / 1 hour / Until…);
     - the circle, reading "Lock now" plus "until 11:46 PM";
     - the overlap or conflict note, if any;
     - then Tonight and Your rhythm.
   - **Locked:**
     - title "Locked", with the origin line ("Focus · you started it", "Bedtime", "Bedtime + Focus");
     - a non-interactive circle in the session colour with `lock.fill` and "until" plus the time hero;
     - then the recovery card and Ask a trusted person, where Tonight was.
   - **Transition:** a colour and content cross-fade in place, which is instant under Reduce Motion.
3. **Active lock** (superseded by 2b for layout; copy rules stand): a full-width hero card in the session's colour with "Locked until 7:00 AM" as the time hero. Below it sit the origin ("Bedtime" or "Focus"), then recovery and "Ask a trusted person". Mood headlines are removed.
4. **Copy pass:** one sentence per control. Policy detail moves to confirmation screens or info disclosures. Times use "10:00 PM" or "Tomorrow 7:00 AM".
5. **People:** a person-centred list with avatar initials in rest colour. Invite becomes one primary action. Prototype items get a dashed outline and a "Prototype" label.
6. **Settings:** native grouped `Form` styled with the tokens, with Developer last and visually distinct.

Each step goes through the UX review gate (AGENTS.md) on owner-approved screenshots.

## 7. Progress

- **D1 (tokens, Lockbox tab, active lock, Lock now / Recovery copy):** merged 2026-11-06 (9a0b39c).
  - Builder: Claude Sonnet 5.5. Reviews: Claude Opus 5.5, an initial review and two delta reviews, no P1.
  - Validation: a compile-only simulator build, and `swift test` 210/0 (including the new `RuntimeTimeFormat`/`RuntimeActiveLockDisplay` tests).
  - No simulator run (owner rule).
  - Build 25 is installed on the owner's iPhone for hands-on review.
  - The UX review gate is still owed, on owner screenshots or an owner-approved suite run.
- **D1b (Lock now hero circle, §6.2a):** merged 2026-11-06.
  - Builder: Claude Sonnet 5.5. Review: Claude Opus 5.5, no P1 or P2. All five P3s handled: the not-determined access path, the disabled VoiceOver hint, a softer halo, icon sizing, and the centred header, which was left for the owner to judge.
  - Validation: compile-only builds, and `swift test` 210/0. No simulator run.
  - Build 26 is installed on the owner's iPhone.
- **Next:** D2 People, then D3 Settings.
