# Quick Actions candidate

Phone Lockbox includes a source-only Shortcuts/App Intents candidate for four bounded navigation actions:

- start a 30-minute focus session;
- start a one-hour focus session;
- show the current Lockbox status; and
- open Recovery.

The two focus actions open the existing **Lock now** sheet with the requested preset selected. The user must review and explicitly confirm the finite end; a shortcut never applies Managed Settings directly. Recovery opens the existing delayed recovery flow, and status opens the normal Lockbox surface. Authorization, registration and enforcement remain reported by the app and are never inferred from an accepted intent.

Routes use the `phonelockbox://quick-action/v1/...` scheme configured in `project.yml`. Each generated route is short-lived and includes an issued and expiry timestamp. The parser accepts only the exact versioned paths and query allowlist; unknown, malformed, future-dated or expired routes fail closed without changing a rule, active session or recovery state.

This is a source candidate only. Siri/Shortcuts availability, voice feedback, duplicate invocation and device behavior still require the R9 acceptance gate. No installation, Siri prompt, schedule change or enforcement result is implied by this implementation. Indefinite locks, background enforcement, instant recovery and active-rule edits are deliberately not exposed.
