# ADR 0012: PowerShell runtime bootstrap

## Status

Accepted

## Context

Winix plugins require PowerShell 7, including the plugin that manages PowerShell modules. An ordinary plugin cannot install the runtime needed to execute itself. Requiring every user to prepare PowerShell manually would leave a core startup dependency unmanaged.

## Decision

PowerShell 7 is part of the Winix execution environment rather than ordinary managed configuration.

On startup, the Rust host selects a runtime in this order:

1. `WINIX_PWSH`, when explicitly provided;
2. a compatible `pwsh` available through `PATH` or a standard installation location;
3. a newly bootstrapped installation.

When bootstrap is required, Rust directly runs WinGet to install the latest `Microsoft.PowerShell` package. No version is pinned. Winix captures complete standard output and error output on failure, locates `pwsh.exe` after installation without relying on a refreshed process `PATH`, and verifies that it is PowerShell 7 or newer before invoking a plugin.

Runtime bootstrap occurs before configuration validation and planning. It is analogous to installing Winix itself and does not appear in the managed configuration plan. PowerShell modules and the public machine PowerShell package may still be managed as ordinary resources; they do not determine the runtime selected for the current process.

## Consequences

- A first run requires either an existing PowerShell 7 installation or a working WinGet installation and network access.
- Winix distributions remain small and do not bundle PowerShell.
- The PowerShell version installed on first bootstrap follows the current WinGet catalog.
- Offline and WinGet-free bootstrap are deferred. A bundled portable runtime can be added later without changing the plugin protocol.
