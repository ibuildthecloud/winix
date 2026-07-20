# ADR 0013: Pluggable WinGet metadata with native mutation

## Status

Accepted

## Context

The original WinGet provider repeatedly launched `winget.exe` and parsed human-readable output for installed state, catalog versions, applicability, and mutations. Planning both configured scopes took about 33.7 seconds on the development machine.

`Microsoft.WinGet.Client` provides structured catalog objects and native package-management cmdlets. Its public installed-package model, however, does not preserve all registrations when the same package exists at both user and machine scope. In testing, a bulk query returned only Node's machine registration while an exact query returned only its user registration. `Uninstall-WinGetPackage` also has no scope parameter. Its `-WhatIf` installer-applicability path took roughly 30 seconds for a package, while the CLI scope query remained fast.

## Decision

Catalog resolution and version comparison use a pluggable metadata backend. The native `Microsoft.WinGet.Client` backend is the default. `Devolutions.Pinget.Client` 0.10.0 remains available as an experimental opt-in selected with `WINIX_WINGET_METADATA_BACKEND=pinget`; it falls back to native metadata when the module is unavailable or cannot resolve historical version metadata.

The provider continues to use `Microsoft.WinGet.Client` for installation and update. It uses scope-qualified `winget list` for installed-state observation, scope-qualified `winget show` for installer applicability, and scope-qualified `winget uninstall` for removal. These mutation, stale-plan, scope, and postcondition paths are deliberately independent of the metadata backend.

Independent installed-state queries are run concurrently within the single planning PowerShell process. Normal planning invokes each plugin once; runtime validation is part of the plan handler rather than a separate process. The standalone `validate` command remains available and performs catalog identity validation.

The fallback is required for correctness and is not replaced with inference from undocumented registration identifiers. Every mutation remains represented in the closed operation queue and apply still performs stale-plan preflight and postcondition verification.

## Consequences

- Planning avoids a separate PowerShell validation process and most sequential WinGet process latency.
- Catalog and version-comparison results use a replaceable structured backend; successful install/update results remain structured Microsoft client results.
- Scoped uninstall retains the CLI's full captured diagnostic output.
- The provider remains hybrid until an alternative backend proves lossless scoped inventory, efficient applicability, and scoped uninstall.
- On the comparable two-scope fixture, plan time fell from about 33.7 seconds to about 18.3 seconds.
