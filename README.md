# Phone Lockbox

A planned native iPhone app that keeps essentials available while restricting nighttime app-hopping. Personal use first, with possible public release later.

**Status:** planning only. No app, build, or real-device enforcement tests yet.

## Plan

- [Product plan](docs/product-plan.md): goals, scope, acceptance criteria, and phased delivery.
- [Interaction design](docs/interaction-design.md): setup, lock states, rule changes, and deliberate recovery.
- [Technical plan](docs/technical-plan.md): Apple framework integration, feasibility gates, architecture, and validation.

Start with real-device blocking and scheduled-release experiments, then build the bedtime MVP. The schedule and essentials list are user-configurable. A minimalist launcher is deferred.

## Constraints

This is a self-control tool, not a tamper-proof device lockdown. iOS system exclusions, authorization revocation, and uninstall remain limitations. Exact blocking coverage and reliability must be established on a physical iPhone.

The planned app is local-only and requires no backend or HTTP listener. Development will require suitable Apple signing capabilities and a physical iPhone; setup commands will be documented once an Xcode project exists.
