# Releasing Winix

Winix is pre-1.0 and currently built from source. There are no published binary releases yet. This document records the release policy and the quality gates required before publishing artifacts.

## Version and platform policy

- Versions follow semantic versioning. Before 1.0, a minor version may contain intentional configuration or protocol changes; document them in release notes.
- The supported operating-system baseline is the latest generally available Windows 11 Home release, as defined by [ADR 0020](adr/0020-windows-support-baseline.md).
- A release is the Rust binary together with the exact plugin manifests, schemas, entrypoints, and shared PowerShell code tested for that version. Do not mix a binary from one release with plugins from another.
- Release builds must disable repository development paths and resolve plugins from the installed, administrator-owned location.
- Only the latest published pre-1.0 release receives fixes. This policy can be expanded when stable releases and supported upgrade paths exist.

## Generated schema policy

[`winix-cfg.schema.json`](../winix-cfg.schema.json) is a checked-in generated artifact. Plugin manifests and `schema.json` files are authoritative. Any source-schema change must include a regenerated root schema:

```powershell
cargo run -- schema --output winix-cfg.schema.json
```

CI regenerates the schema and rejects a diff. The checked-in file lets editors validate examples without requiring a local build first.

## Release gate

Before creating a tag:

1. Confirm the accepted blockers in the [initial quality and security review](reviews/2026-07-20-initial-quality-security-review.md) that apply to the release have been closed or explicitly documented.
2. Run the same formatting, Clippy, Rust tests, schema reproducibility, plugin discovery, example-validation, PSScriptAnalyzer, and PowerShell/C# compilation checks as CI on a clean checkout.
3. Build with locked dependencies and production paths:

   ```powershell
   cargo build --release --locked --no-default-features
   ```

4. Exercise validate, plan, first apply, converged second apply, stale-plan rejection, and reboot-required behavior on a disposable clean Windows 11 Home VM.
5. Verify that the staged bundle contains only the intended executable, plugins, schemas, shared runtime files, license, and release documentation.
6. Record behavior changes, schema changes, destructive operations, privilege changes, generated-file changes, and validation evidence in the release notes.
7. Generate checksums and an SBOM. Sign the release artifacts when the project has established a protected signing identity.

Do not publish a binary assembled manually from an uncommitted or dirty worktree. Published artifacts should be produced by a protected GitHub Actions release workflow once that workflow exists.
