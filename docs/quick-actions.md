# Quick Actions candidate

Phone Lockbox includes a source-only Shortcuts/App Intents candidate for four bounded navigation actions:

- start a 30-minute focus session;
- start a one-hour focus session;
- show the current Lockbox status; and
- open Recovery.

The two focus actions open the existing **Lock now** sheet with the requested preset selected. The user must review and explicitly confirm the finite end; a shortcut never applies Managed Settings directly. Recovery opens the existing delayed recovery flow, and status opens the normal Lockbox surface. Authorization, registration and enforcement remain reported by the app and are never inferred from an accepted intent.

Routes use the `phonelockbox://quick-action/v1/...` scheme configured in `project.yml`. Each generated route carries a unique nonce for queue deduplication, an integer issuance time, and an exact five-minute expiry. The parser accepts only canonical absolute paths, canonical integer values, the exact query allowlist, and routes within the bounded issuance-age and clock-skew window; unknown, malformed, duplicate, future-dated, stale, or expired routes fail closed without changing a rule, active session or recovery state. These values are freshness and delivery metadata only, not authentication or provenance.

The App Group handoff is a bounded, versioned file queue under its own cross-process lock and atomic writes. Enqueue is ordered and deduplicated by nonce. App consumption uses a short lease with explicit acknowledgement, so an app crash can retry navigation and an enqueue cannot be deleted by a concurrent consume. Corrupt or unavailable queue storage fails closed. This is a source candidate only. Siri/Shortcuts availability, voice feedback, duplicate invocation and device behavior still require the R9 acceptance gate. No installation, Siri prompt, schedule change or enforcement result is implied by this implementation. Indefinite locks, background enforcement, instant recovery and active-rule edits are deliberately not exposed.
