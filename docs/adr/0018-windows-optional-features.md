# ADR 0018: Windows optional features

- Status: Accepted
- Date: 2026-07-20

## Context

Windows Settings presents both classic optional features and Features on Demand in its optional-features UI. The servicing APIs expose them through separate catalogs. In particular, Wireless Display is the capability `App.WirelessDisplay.Connect~~~~0.0.1.0`, not a `Get-WindowsOptionalFeature` feature. Both catalogs can report that a successful no-restart mutation still requires a system restart, and their visible state may already look enabled or disabled during that boot.

## Decision

The system-only `windows.features.optional` plugin manages a map keyed by native resource identity. Each entry declares `provider: capability` or `provider: feature` and a desired `enabled` or `disabled` state. Capabilities use the Windows Capability cmdlets; classic features use the Windows Optional Feature cmdlets. Classic-feature disablement retains the feature payload.

Classic feature keys must be exact. A capability key may omit its tilde-delimited qualifier and version suffix. The plugin accepts that shorthand only when it matches exactly one live catalog entry, preserves canonical casing, and binds the full native identity into the closed operation queue and restart receipt. Ambiguous shorthand is rejected with the candidate identities. Localized display-name aliases are not supported.

Planning and applying servicing state require elevation. `plan` and `apply` request UAC for an explicitly selected system phase when the coordinator is unelevated; an elevated coordinator runs that phase directly.

The inbox DISM PowerShell module is hosted by noninteractive Windows PowerShell. Some Windows 11 installations expose its servicing CDXML classes only there and return `Class not registered` when the cmdlets are loaded directly by PowerShell 7. The plugin passes only typed resource data through dedicated environment variables and captures the child process output as JSON so the plugin's NDJSON stream remains clean.

When a servicing cmdlet reports `RestartNeeded`, apply records the resource, desired state, and numeric boot identity in a machine-local receipt. Capability cmdlets do not expose `-NoRestart`; they report restart status without initiating a restart. Classic optional-feature mutations explicitly use `-NoRestart`. Later plans during the same boot return `state.restart_pending: true`, no additional operation for that resource, and `restart_required.system: true`. After a different boot, the receipt no longer indicates a pending restart and ordinary catalog observation determines convergence.

## Consequences

- Configuration uses stable, non-localized servicing identities and may omit capability qualifier/version suffixes when unambiguous.
- Wireless Display and classic optional features share one semantic desired-state surface without conflating their native providers.
- Winix never restarts Windows itself and continues to return exit code 3010 on subsequent runs until the required restart occurs.
- Feature parent dependencies may be enabled by Windows through `-All`; they remain unmanaged unless separately declared.
