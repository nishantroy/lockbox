# relay-smoke

A small, reusable Swift command-line smoke test for the R5 companion relay
(`relay/`, see `docs/r5-relay-plan.md`). It exercises the same flow
`PhoneLockbox/Companion/CompanionCoordinator.swift` drives in the app —
invite, accept, confirm, pairing discovery, bilateral consent, an exact
session, an early-end request, approval, and revocation — against a real
relay over HTTP.

## Usage

```
swift run --package-path tools/relay-smoke relay-smoke [baseURL]
```

`baseURL` defaults to `http://127.0.0.1:8002` (the local relay; see
`relay/README.md` and the port registry in `/Users/nishantroy/code/AGENTS.md`).
To run against another relay, e.g. the deployed one:

```
swift run --package-path tools/relay-smoke relay-smoke https://relay.example.com
```

The tool creates two fresh, in-memory, throwaway identities (an owner and a
helper) for the run. Nothing is persisted: no Keychain, no App Group, no
files written. The owner's rollback anchor lives only in an in-memory
`RollbackAnchorStore` for the lifetime of the process.

Each step prints `PASS <name>` or `FAIL <name>: <reason>` as it runs, then a
one-line summary. The process exits non-zero if any step failed.

## Scope

`tools/relay-smoke/` is a standalone SwiftPM package that depends on
`CompanionKit` by local path (`../../CompanionKit`). It does not modify
`CompanionKit/`, `relay/`, `Shared/`, or `PhoneLockbox/`.

The companion "active set" ID derivation
(`RuntimeActiveSet.id(for:)` in `Shared/RuntimeFriendRelease.swift`) is
duplicated here rather than imported, since this package owns only
`tools/relay-smoke/**`.
