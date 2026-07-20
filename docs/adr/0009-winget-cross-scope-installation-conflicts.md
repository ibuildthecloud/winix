# ADR 0009: WinGet cross-scope installation conflicts

- Status: Accepted
- Date: 2026-07-19
- Decision owners: Winix maintainers
- Refines: ADR 0008

## Context

A package installed for the machine does not satisfy a package declared in a user's configuration, and the reverse is also true. However, the scope-neutral user install required by ADR 0008 allows WinGet to discover an existing machine installation. WinGet may then reinterpret `install` as an upgrade and fail with "No available upgrade found" instead of creating the requested user installation.

This behavior is particularly dangerous when several packages are being applied: discovering the conflict after earlier mutations would leave a partially applied configuration.

## Decision

The WinGet plugin treats an installation in the opposite scope as a configuration conflict, not as satisfied state and not as an installation candidate.

Before any `set` mutation, the plugin observes every requested package in its desired scope. When an installed package is missing from that scope, it also checks the opposite scope. If any opposite-scope installation exists, the plugin:

- emits `resource_status` with `status: scope_conflict`;
- emits a structured `winget.package.scope_conflict` diagnostic containing the desired and installed scopes;
- returns an unsuccessful structured result and rejects the entire plugin operation before making changes. Expected preflight conflicts do not use PowerShell exceptions or expose stack traces.

Console consumers present the diagnostic message, configuration path, and concrete remediation. Machine-to-user conflicts direct the user to move the package declaration to `system.packages.winget` and use `apply --all`, or to remove the machine installation first.

The user must either place the package under the scope where it is already installed or remove that installation before applying it in the other scope. Winix will not automatically uninstall or migrate packages across privilege boundaries.

## Consequences

- Scope remains part of desired-state identity.
- Scope-neutral installers cannot accidentally target an existing package in the wrong scope.
- A WinGet plugin invocation does not partially mutate packages before reporting a known cross-scope conflict.
- Moving a package between scopes remains an explicit user decision.
