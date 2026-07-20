# ADR 0008: WinGet scope-neutral user installers

- Status: Accepted
- Date: 2026-07-19
- Decision owners: Winix maintainers
- Refines: ADR 0007 and the WinGet privilege guidance following ADR 0005

## Context

Winix initially translated user placement directly into `winget --scope user`. WinGet treats this argument as a strict installer-selection requirement. An installer manifest that omits `Scope` can therefore be excluded even when it naturally installs for the invoking user without elevation.

`Rustlang.Rustup` is one such package. Its installer manifest declares neither `Scope` nor `ElevationRequirement`; `rustup-init.exe` installs into the invoking user's profile. Requiring manifest scope `user` makes valid user configuration fail, while moving Rustup into system configuration would give it the wrong identity and installation location.

The current WinGet CLI does not expose selected-installer scope or elevation metadata as structured output and has no no-change installer-selection command. Winix cannot presently prove that every scope-neutral third-party installer will avoid independently requesting UAC.

## Decision

Configuration placement continues to define the required process privilege and desired installed-package scope. It is not translated mechanically into the same WinGet argument for every subcommand.

For user placement:

- Winix runs WinGet only in the original unelevated current-user process.
- Installed-state queries use `winget list --scope user` so a machine installation does not satisfy user desired state.
- Uninstall uses `winget uninstall --scope user` so it cannot select a machine installation.
- Planning probes installer applicability with `winget show --scope user` and `--scope machine` for the requested version on the current OS and architecture.
- When a user installer is applicable, install and upgrade force `--scope user`.
- When only a machine installer is applicable, planning fails with `winget.package.requires_machine_scope` before mutation.
- When neither scoped probe is applicable but an unscoped probe is, the installer is classified as scope-neutral and install/upgrade omit `--scope`. This permits Rustup-like installers while retaining postcondition verification from ADR 0010.
- Applicability metadata is not treated as proof. ADR 0010 postcondition verification remains authoritative when actual registration contradicts the selected scope.
- Winix never retries a failed user installation through the elevated system worker.
- Any unexpected third-party UAC prompt must be rejected by the user; cancellation is reported as a structured package failure.

For system placement, list, install, upgrade, and uninstall continue to use `--scope machine` and execute only in the elevated system worker.

User plugin validation and apply continue to fail before mutation when `winix-cfg` itself is elevated.

When WinGet exposes reliable selected-installer metadata through a supported structured API, Winix should add preflight rejection for explicit machine scope and `ElevationRequirement: elevationRequired`. Missing metadata cannot currently be treated as machine scope because that would reject legitimate scope-neutral installers.

## Consequences

### Positive

- Rustup and similar scope-neutral installers work in user configuration.
- Machine installations do not incorrectly satisfy user desired state.
- User uninstall remains constrained to the current user's installation.
- Winix itself never requests or supplies elevation for user packages.

### Negative

- A scope-neutral or incomplete third-party installer can independently request UAC.
- Winix cannot automatically intercept the secure-desktop prompt with the current CLI integration.
- WinGet CLI applicability output is human-readable rather than a stable structured manifest API, so parsing remains an integration risk.
- A manifest may advertise user scope without supplying installer switches that actually produce a user registration; Winix reports that contradiction after installation rather than maintaining package/version exceptions.

## Deferred decisions

- WinGet COM/API integration for selected-installer metadata.
- Trusted package compatibility metadata for known scope-neutral installers.
- Automatic prevention of arbitrary installer elevation through a supported Windows isolation mechanism.
