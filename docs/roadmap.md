# Quality and security roadmap

This is the living implementation tracker for the findings accepted in the
[initial quality and security review](reviews/2026-07-20-initial-quality-security-review.md).
The review remains the evidence-backed baseline; this document records delivery
status. `apply` remains Winix's primary workflow throughout this work.

Status values are **complete**, **in progress**, and **pending**. A phase is
complete only when all of its exit criteria are enforced by automated tests or
the documented Windows 11 Home release process.

## Phase 0 — Safety baseline and repeatable gates

Status: **complete**

- [x] Publish the repository with a safe, reversible Quick Start.
- [x] Add a pinned Windows CI gate for formatting, warnings-as-errors Clippy,
      locked tests in both feature modes, and a production release build.
- [x] Gate PowerShell syntax and analysis, plugin/schema completeness, embedded
      C# compilation, and Pester 5 helper tests.
- [x] Track the composed root schema and fail CI when regeneration produces a
      Git diff.
- [x] Cover JSON-semantic equality after reordered-property round trips.
- [x] Cover plan ordering independently of JSON object property order and exact
      dependency identity without suffix collisions or self-dependencies.
- [x] Reject malformed protocol success/results and operation envelopes at the
      Rust boundary.
- [x] Guarantee a structured terminal failure event for every started top-level
      operation.
- [x] Prove elevated validation never executes user placement with an elevated
      token.
- [x] Prove a stale later operation causes zero earlier mutation in affected
      PowerShell plugins.

Exit criteria: every item above passes locally and in the hosted Windows gate.

## Phase 1 — Privilege and plan integrity

Status: **pending**

- [ ] Make administrator-owned installed plugin paths the production default;
      require explicit development-path opt-in and prevent accidental elevation.
- [ ] Canonicalize and verify PowerShell and native executable identities and
      sanitize the elevated worker environment.
- [ ] Bind configuration, ordered plan, plugin bundle, and runtime identity
      across discovery, planning, elevation, and apply.
- [ ] Route user placement through a verified limited token for every phase.
- [ ] Replace command-line and ordinary temporary-file worker transport with an
      access-controlled, authenticated per-operation channel.
- [ ] Remove, defer, or redesign outcomes that cannot be verified on supported
      Windows 11 Home consumer surfaces.

Exit criteria: no elevated path loads unverified code or executables, and the
reviewed plan and trusted runtime bundle are inseparable at apply.

## Phase 2 — Typed protocol and uniform apply semantics

Status: **pending**

- [ ] Introduce strict typed request, result, event, operation, scope, restart,
      and error envelopes while leaving plugin-specific operation data open.
- [ ] Use one authoritative ordered plan representation and exact plugin IDs for
      dependency lookup.
- [ ] Centralize two-pass queue preflight, mutation, postconditions, and partial
      failure reporting in shared PowerShell support.
- [ ] Correct the audited ARP, MSI, AppX, WSL, WinGet, Nerd Fonts, registry,
      manifest, and executable-resolution defects.
- [ ] Add bounded I/O, deadlines, cancellation, process-tree cleanup, fallible
      event sinks, and one terminal event per started operation.

Exit criteria: malformed protocol data fails closed and every plugin obeys the
same queue and failure contract.

## Phase 3 — Testability and maintainability

Status: **pending**

- [ ] Separate protocol, planning, catalog, events, process supervision, and
      Windows platform code behind a library boundary.
- [ ] Inject filesystem, environment, process, elevation, identity, time, and
      plugin-runner seams.
- [ ] Build Pester contract/provider coverage for every plugin.
- [ ] Make every configuration fixture executable and cover invalid input,
      convergence, stale plans, postconditions, placement, privilege, reboot,
      and stdout cleanliness.
- [ ] Add disposable Windows 11 Home VM convergence scenarios.

Exit criteria: core orchestration is testable without live mutation and every
plugin has automated contract coverage.

## Phase 4 — Release provenance

Status: **pending**

- [ ] Build a versioned binary/plugin/schema bundle only from protected CI.
- [ ] Publish checksums and an SBOM and sign artifacts with a protected identity.
- [ ] Enforce dependency advisory, license, and source policies.
- [ ] Document upgrade, recovery, reboot, destructive-operation, and platform
      compatibility behavior for each release.

Exit criteria: a release is reproducible, attributable, integrity-verifiable,
and validated on the supported Windows 11 Home baseline.
