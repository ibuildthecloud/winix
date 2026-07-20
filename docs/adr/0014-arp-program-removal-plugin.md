# ADR 0014: ARP program removal plugin

- Status: Accepted
- Date: 2026-07-19
- Decision owners: Winix maintainers

## Context

Some machine programs register with Add/Remove Programs but are neither MSI products nor correlated with a durable WinGet catalog identifier. Examples include Office Click-to-Run and the standalone Copilot application.

## Decision

The system-only `arp` plugin registers at `packages.arp`. Keys are exact uninstall-registry subkey names, paired with an expected display name to prevent accidental removal if a vendor reuses a key. Configuration remains declarative and supports `state: absent` only.

The plugin executes no command supplied by configuration. It reads the registered uninstall command and permits only provider implementations with a known non-interactive strategy and provider-specific success codes. The first providers are Office Click-to-Run and the Chromium-style Copilot installer, whose successful uninstall status is 19. Apply runs elevated and verifies registry absence.

## Consequences

- Non-MSI programs can have durable desired-absence declarations.
- Unsupported installer technologies fail validation instead of opening interactive uninstallers.
- Provider strategies must be added and tested explicitly.
