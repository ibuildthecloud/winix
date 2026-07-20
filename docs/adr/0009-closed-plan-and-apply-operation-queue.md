# ADR 0009: Closed plan and apply operation queue

- Status: Accepted
- Date: 2026-07-19
- Decision owners: Winix maintainers

## Context

Plugins previously combined state discovery and mutation in one `set` operation. A plugin could therefore discover new work while applying, invoke provider defaults such as WinGet's moving `latest` target, or report a change that had never appeared during inspection. This is incompatible with predictable declarative configuration.

## Decision

Every mutation uses three conceptual phases:

1. **Observe** reads current machine state and provider or catalog state.
2. **Plan** returns a closed ordered array named `operations`. Each operation has a stable `id`, typed `action`, `resource`, concrete `before` and `after` values, and provider-specific `data`.
3. **Apply** receives that exact array and may execute only those operations, in order.

The version 2 plugin transport operations are `validate`, `plan`, and `apply`. Planning performs runtime validation, observation, and planning in one side-effect-free plugin process; a plan handler must not assume that a separate `validate` invocation occurred. The standalone validation command uses `validate` when no state plan is requested. Apply runs in a separate process. Every selected plugin within a scope is planned successfully before that scope's first mutation. During `apply --all`, system planning and apply occur in the elevated worker before current-user planning so UAC is requested up front and user observation sees established system postconditions.

The engine enforces that every plan contains an operation array with unique string IDs, no apply process is started for an empty plan, the apply result returns the same queue, and successful apply accounts for exactly the planned operation IDs in their planned order.

Before its first mutation, a plugin must re-read and validate the preconditions for its entire queue. Any mismatch makes the plan stale and fails without mutation. A plugin must not silently refresh, re-plan, append, replace, or omit operations during apply.

Plans contain typed intent rather than executable command strings. Plugins reconstruct native commands from validated fields.

## WinGet semantics

WinGet planning records installed versions and queries applicable catalog versions. The `latest` policy resolves to a concrete version during planning. Install, upgrade, and downgrade commands receive that concrete version during apply. An omitted version accepts any installed version, but installation of a missing package still resolves to a concrete catalog version.

An installed version newer than the current catalog satisfies `latest`; it is never implicitly downgraded. An exact version mismatch produces an upgrade or downgrade only when version ordering can be determined. Otherwise planning fails.

Package scope and cross-scope conflicts are resolved during planning. Apply rechecks installed scope and version before running any command.

When `--all` plans a system-scope uninstall followed by a user-scope install of the same package, the latter operation records the former operation ID as a prerequisite. A user-only plan cannot assume that a system operation will occur and therefore rejects the same conflict.

WinGet and installers can perform provider-managed internal work such as installing declared dependencies or changing application-owned files. Those effects belong to the planned package transaction; Winix does not currently model them as independent resources.

## Failure and atomicity

Planning is side-effect free. Preflight is all-or-nothing, but apply is not transactional: registry writes and third-party installers cannot generally be rolled back safely. If an operation fails after earlier operations complete, the plugin reports the completed IDs and stops. A later plan observes the partial state.

## CLI behavior

`winix-cfg plan` exposes the concrete queue without mutation. `winix-cfg apply` creates an ephemeral plan and immediately consumes it. Persisted plan artifacts, approvals, cryptographic binding, expiration, and replay are deferred. A future persisted plan must bind configuration content, device, scope, user identity, plugin identity and version, and observation metadata.

## Consequences

- Plugins cannot perform unplanned mutations through the normal engine protocol.
- `latest` remains convenient while apply is pinned and reproducible for that run.
- State drift fails safely instead of changing the queue.
- New plugins must model concrete operations and preconditions before they can mutate state.
- Apply can still partially complete when an external tool fails mid-queue.
