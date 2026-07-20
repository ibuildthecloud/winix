# ADR 0014: Nerd Fonts installation plugin

- Status: Accepted
- Date: 2026-07-19
- Decision owners: Winix maintainers

## Context

Winix needs a declarative way to install font families, particularly patched developer fonts. The official `ryanoasis/nerd-fonts` project publishes a well-known catalog of complete family archives as GitHub release assets. Generic collections such as Google Fonts are useful future sources but do not distribute the patched Nerd Font families.

Font family names, internal face names, and archive names are different identities. For the official release catalog, the ZIP asset basename is stable, unambiguous, and directly resolvable without maintaining a second catalog in Winix.

## Decision

The `nerd-fonts` plugin registers at `fonts.nerd_fonts` for system and current-user placements. Configuration is a resource map keyed by the exact, case-sensitive release ZIP basename, such as `JetBrainsMono`, `FiraCode`, or `Hack`.

The plugin supports `state: installed` and `state: absent`; omission means installed. Removal is ownership-safe and applies only to a family with a Winix receipt. Upgrades of already managed families, adoption of externally installed fonts, arbitrary font URLs, and other catalogs are deferred until their identity and safe replacement semantics are designed.

Runtime validation queries the latest official GitHub release and requires an exact matching ZIP asset. Planning downloads the selected archive into temporary storage, records its concrete release tag, URL, SHA-256 digest, and font file list, then deletes the temporary files. Apply downloads that exact asset, verifies the digest and file list, checks the full queue for stale managed state before mutation, and installs through the Windows Fonts shell namespace.

The plugin writes a scope-specific receipt only after Windows reports every planned font filename in the corresponding Fonts registry key. Receipts live beneath `%ProgramData%\Winix\fonts\nerd-fonts` for system scope and `%LOCALAPPDATA%\Winix\fonts\nerd-fonts` for current-user scope. A complete receipt plus registry registration is the managed-state postcondition. Uninstall deregisters and deletes only the files named by that receipt, broadcasts `WM_FONTCHANGE`, verifies their removal, and then deletes the receipt.

## Consequences

- Configuration is compact and uses the upstream catalog's semantic identity.
- Apply is bound to the release content inspected during planning rather than a moving latest URL.
- Users can manage Nerd Fonts without installing Scoop, Chocolatey, or a third-party PowerShell module.
- Planning requires GitHub access and downloads each family archive when no complete receipt exists.
- Fonts installed outside Winix are not adopted automatically in this first implementation.
- In-place upgrades remain future work because loaded Windows fonts can prevent replacement.
