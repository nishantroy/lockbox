# UX/design-polish review: People pairing flow (r5-relay 20397f9)

Reviewer: Claude Opus, independent; review only. Inputs: the pre-push UI suite screenshots 01–08 (iPhone Air simulator), `PeopleView.swift`, the strings in `CompanionCoordinator.swift`, the P3c plan sections, checked against the AGENTS.md gate, `layout-v1-contract.md`, `design-polish.md` and `interaction-design.md`. Not seen: a bottom-scrolled screenshot and large Dynamic Type sizes, so those were checked from code. Owner decision (2026-10-31): fix everything except P2-5 and P3-2, which are deferred.

## P1 (must fix)
- **P1-1. No confirmation for the friend after Accept** (05). The invite card disappears and owner-setup cards take over. "People you're helping" sits at the bottom, under the tab bar. Fix: a one-time, dismissable notice at the incoming-invite position, scrolled to like `scrollToJoinedNotice`. Title "You're now a trusted person for Dana", body "Dana can ask you to approve ending a lock early. You'll see requests here." Same badge and dismiss style as `JoinedNoticeCard`.
- **P1-2. The friend's pending request is off-screen** (06 looks the same as 05). Fix: while any inbox item has `!isMine && status == .pending && myDecision == .pending`, render those rows in a "Waiting for you" card directly below the incoming-invite and notice slots, above everything else. Do the same for the owner's approved request that has the "End lock now" action. History stays in the Inbox.
- **P1-3. Name in profile (owner decision).**
  - Remove from `InviteSomeoneCard`: the "Your name" field, "They'll see this name on your invite.", the "Invites are sent as … · Edit" row, Save name/Cancel and `isEditingName`.
  - Remove the name field and "Dana will see this name." from `IncomingInviteCard`.
  - First time only, with no name set: one inline "Your name" field in whichever card is in use.
    - Footnote, friend: "Dana will see this name. You can change it in Settings."
    - Footnote, owner: "People you invite will see this name. You can change it in Settings."
    - A valid name enables the primary button. Tapping Create or Accept saves the name and continues; there is no separate Save step.
  - Settings: one "Your name" row, footer "Trusted people see this name on invites and requests."
  - Merge `ownerDisplayName` and `approverDisplayName` into one stored name. Migrate existing values, preferring the owner name, then the approver name.
  - :813 becomes "Add your name so they know the invite is from you."
  - :992 becomes "Add your name so Dana knows it's you." (use the owner's real name).
  - `showsAcceptInviteFirst` must no longer key on the name: use `pendingInvite == nil && people.isEmpty`, or "has never created an invite".

## P2 (should fix)
- **P2-1. Card order.**
  1. Incoming invite
  2. Joined or accepted notices
  3. Waiting for you
  4. Ask to end early (only while locked)
  5. Your trusted people / People you're helping
  6. Invite a trusted person
  7. Got an invite link?
  8. Inbox history
  9. Notices

  Show `IntroCard` only while `people.isEmpty`. Keep the existing first-run order, with "Got an invite link?" before the owner invite when a link was opened or on first run.
- **P2-2. Explanatory text.** Fold `IntroCard` into the invite card for first run.
  - Title: "Set up a trusted person".
  - Body: "Send a link to someone you trust. Once they accept, they can approve ending a lock early, only when you ask. Your apps and usage are never shared."
  - While a link is live: "The link works once, for one hour."
  - Drop "When they tap Accept, they appear under your trusted people. There's nothing for you to confirm.", "No account, email or code…", "(Messages, AirDrop)" and "Having the link never unlocks anything by itself."
- **P2-3. Create button while a link is live.** Hide the big Create button and show a small plain button "Make a new link" under Copy link. Drop "Invite link ready", but keep the `inviteSomeone.inviteLinkText` identifier and accessibility value for the UI tests, attached to a remaining element. With no link the button reads "Create invite link"; an expired link keeps the primary "Create a new invite".
- **P2-4. "Relay" jargon.**
  - :678 becomes "Couldn't connect. Check your internet connection and try again."
  - :967 becomes "Couldn't connect. Check your internet connection, then open the link again."
  - :1623 becomes "Couldn't connect. Pull down to finish."
  - :680 becomes "Got a response this version can't read. Try again later."
  - :708 becomes "That didn't go through. Try again."
  - Integrity and conflict messages (:701–707, :1012, :1055, :1924) say "the server" instead of "relay".
- **P2-5. App-wide empty navigation bar band.** DEFERRED by owner to its own slice.
- **P2-6. Accept / Not now at accessibility text sizes.** Use `ViewThatFits { HStack; VStack }`.
- **P2-7. Hint copy** (PeopleView ~:702): "None of your trusted people can be asked right now. Their status is shown below; you can send a new invite from there."

## P3 (polish)
- **P3-1. Copied transition.** Add `.contentTransition(.symbolEffect(.replace))` and `.animation(.snappy, value: copied)`. VoiceOver label in that state: "Link copied".
- **P3-2. Prototype card explanation.** DEFERRED (the card goes when the friend-unlock flag is removed).
- **P3-3. Paste fallback.** Replace the TextField and disabled "Open invite" with a SwiftUI `PasteButton` labelled "Paste invite link", keeping the line "Tapping the link opens it here. If it didn't, paste it." Once the user has any person, collapse the card to that single row. Keep a test path: the UI tests use `acceptInvite.pastedInviteField`/`openButton`. Update them, or keep a DEBUG-only route.
- **P3-4. Inbox empty state:** "Nothing here yet. Requests appear here automatically."
- **P3-5. Corrupt-store card:** "Saved invites on this phone are damaged. Reset them to create new invites." Keep the consequences in the dialog only. While corrupt, hide Create instead of disabling it, and drop the "Reset saved invites first" hint.
- **P3-6. Used/expired invite icon:** `exclamationmark.circle` instead of `link.badge.plus`.
- **P3-7. Storage error copy:** "Phone Lockbox couldn't use its storage, so nothing was sent. Quit and reopen the app, then try again."
- **P3-8. Inbox status badges:** explicit copy "Waiting", "Approved", "Declined", "Cancelled", "Expired" instead of `rawValue.capitalized`.
- **P3-9. Next suite run:** add a bottom-scrolled screenshot to check tab-bar clearance, plus screenshots of the new friend notice and Waiting card.

## Good, keep
- The "‹Name› joined" notice.
- Real names throughout.
- The incoming-invite copy, with "You can stop at any time."
- Share as the single primary action.
- Copy feedback.
- Expired-link handling.
- Accept-first ordering after opening a link.
- Named confirmation dialogs for destructive actions.
- Honest "nothing was sent" local errors.
- A corrupt-store reset that only runs when the store really is corrupt.
- Ask buttons named with real names.
- Non-judgmental copy.
