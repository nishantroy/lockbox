## Verdict

**No P0 found. Not yet clear for broader QA due to one P1 lifecycle blocker.** Build-3 owner evidence credibly covers persistence, pending edits, explicit 15-minute recovery, future configuration preservation, and one overnight natural expiry. It does not exercise interruption at the persisted-release/ManagedSettings boundary.

## Findings

### P1 — Interrupted manual release/end may leave shielding until the app is reopened

- `Extensions/DeviceActivityMonitor/MonitorExtension.swift:186`
- `PhoneLockbox/ScreenTimeCoordinator.swift:182-186`
- `Shared/RuntimeLifecycle.swift:98-130`

Recovery and natural end first persist terminal state plus `.clear`, then clear ManagedSettings. If the app/extension is terminated between those steps, `handleManualEnd()` rejects the subsequent callback because it requires an effective manual session. It does not replay an existing `.clear` intent, unlike scheduled end at line 131.

**Risk:** a finite Lock now session can remain visibly shielded after its recorded end/recovery until foreground reconciliation occurs. Add a regression for “terminal manual session + durable clear intent → manual end callback clears policy,” then ensure every callback entry point replays interrupted intent.

### P2 — Disabling recurrence during a manual-only lock leaves the OS daily registration installed

- `PhoneLockbox/ScreenTimeCoordinator.swift:593-611`
- `Extensions/DeviceActivityMonitor/MonitorExtension.swift:181-198`

`stopSchedule()` stops daily monitoring only when *no committed session of any origin* is active. A manual session therefore prevents unregistration, but its end handler never stops the daily activity. Future callbacks are safely rejected by `recurringEnabledIntent == false`, so this should not re-lock, but operational state remains “OS registration remains” until later repair/re-registration.

## Evidence gaps, not established defects

- Reboot/file protection, especially callbacks before first unlock.
- Authorization revoke/restore behavior.
- Exact callback latency, interruption handling, DST/time-zone changes.
- Build-3 category/browser/system/critical-app coverage; earlier category evidence remains useful but is not full native-path coverage.
- VoiceOver, Dynamic Type, contrast, and seven-night reliability.
- Overlap callback-order variants.

## Documentation risk

Evidence files conflict with their own build-3 updates:

- `docs/r2-r3-qa.md:3` still says device acceptance is pending.
- `docs/roadmap.md:136-137` leaves R2/R3 integration unchecked.
- `docs/status-and-qa.md:97,101-102` says overnight is untested and recovery/pending edits are unimplemented.

These stale entries could cause passed owner QA to be repeated or remaining scope to be misreported.

**Validation:** read-only review only; no edits, deployment, or tests run. Existing 56-test evidence was reviewed, but current tests do not cover the P1 callback-replay path.
