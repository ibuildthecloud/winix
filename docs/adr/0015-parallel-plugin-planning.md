# ADR 0015: Parallel read-only plugin phases

- Status: Accepted
- Date: 2026-07-19
- Refines: ADR 0007, ADR 0009, and ADR 0011

## Context

Each plugin is an isolated PowerShell process. Runtime validation and observation are normally the expensive parts of validation and planning. Running plugins serially makes total latency approach the sum of unrelated provider latencies even though both phases are side-effect free.

## Decision

Winix uses one shared concurrent invocation runner for the read-only `validate` and `plan` plugin phases and multiplexes their structured events through the engine. Standalone validation starts configured current-user and system plugin validations together. Planning starts every selected plugin concurrently within one placement scope. All responses must succeed, and plans must pass operation-ID validation, before any apply begins.

System and current-user scopes remain separate phases. Standalone `plan --all` collects the complete system plan before the current-user plan so it can show cross-scope migrations without mutation. `apply --all` instead plans and applies system scope inside the up-front elevated worker, then plans current-user scope against the resulting machine state.

Manifest-required configuration does not serialize planning. After all plans in a scope have returned, Winix resolves provider operation IDs and adds them to each dependent operation's `depends_on` array. Plugin discovery order remains the deterministic apply order, with providers before dependents. Apply is not parallelized.

## Consequences

- Validation latency is bounded primarily by the slowest configured plugin; plan latency is bounded primarily by the slowest plugin in each scope.
- Event sequence numbers remain engine-owned, but events from different plugins may interleave and completion order is intentionally nondeterministic.
- Plugins must not rely on another same-scope plugin having planned or mutated state before their plan handler runs.
- Within a plugin, observation should enumerate each provider inventory once and resolve configured resources from an in-memory index. Mutation must invalidate affected cached observations before postcondition checks.
- Dependencies required merely to observe state still need a side-effect-free bootstrap observation path.
- Explicit planning phases or richer dependency scheduling can be introduced later if a provider cannot plan independently.
