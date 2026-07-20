# ADR 0010: WinGet scope postcondition verification

- Status: Accepted
- Date: 2026-07-19
- Decision owners: Winix maintainers
- Refines: ADR 0008 and ADR 0009

## Context

An unelevated WinGet process can launch an installer that independently requests UAC. If the user approves, WinGet may return success even though a package declared under user configuration was installed machine-wide. Installer exit success alone therefore does not prove that Winix reached the requested state.

Winix cannot reliably observe whether an arbitrary installer displayed or received a UAC elevation. The relevant durable fact is the package scope registered after installation.

## Decision

After every successful WinGet installation command, the plugin re-queries the package at the declared scope. The change is complete only when the package is visible there.

If it is absent from the declared scope, the plugin queries the opposite scope:

- If present there, it emits `winget.package.postcondition.scope_violation` with both scopes and actionable placement guidance.
- If the expected installed/version state is not reached and the package is not present in the opposite scope, it emits `winget.package.postcondition.not_satisfied`.

Both outcomes return an unsuccessful structured result with `changed: true`, because the external installer ran and may have changed the machine even though it did not satisfy desired state. Winix reports but does not automatically uninstall a package that landed in the wrong scope.

An `absent` declaration is scoped only to its own placement. A user-absent package may validly exist at machine scope, and a system-absent package may validly exist at user scope. This permits explicit migrations and prevents one scope from deleting the other's desired package.

## Consequences

- Approved installer elevation cannot silently satisfy the wrong Winix scope.
- Scope verification is based on registered post-install state rather than inference from installer UI.
- Some installers may require users to move declarations from user to system configuration.
- External installer side effects remain possible and are reported as changed failures rather than rolled back automatically.
