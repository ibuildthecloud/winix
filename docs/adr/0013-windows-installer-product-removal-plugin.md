# ADR 0013: Windows Installer product removal plugin

- Status: Accepted
- Date: 2026-07-19
- Decision owners: Winix maintainers

## Context

OEM AppX applications can have machine-wide MSI companion services that are not owned by AppX and are not correlated to a WinGet catalog package. Removing only the visible AppX leaves those services running.

## Decision

The system-only `windows-installer` plugin registers at `packages.windows_installer`. Keys are canonical uppercase MSI product codes including braces. The initial implementation supports `state: absent` only.

Planning reads the 64-bit and 32-bit HKLM uninstall registrations. Apply re-observes the product by its semantic product-code identity. If another planned operation already removed it, the uninstall postcondition is satisfied without error. If it remains installed, metadata drift such as a changed display name, version, or registry view does not prevent the desired removal. Apply invokes `msiexec /x <product-code> /qn /norestart` in the elevated system worker, accepts documented success/already-absent/restart-required exit codes, and verifies removal from ARP registration.

The plugin does not use `Win32_Product`, because querying that provider can trigger MSI consistency checks and repairs.

## Consequences

- MSI companion services have explicit ownership and privilege scope.
- Product-code identity is stable and non-arbitrary.
- Installation and repair are deferred.
- OEM updates that change product codes require an explicit configuration update.
