# Repository Guidelines

## Project Structure & Module Organization

`src/` contains the Rust CLI and engine. `plugins/` contains recursively discovered PowerShell plugins; each plugin directory owns a configuration path and includes `plugin.json`, `schema.json`, and `plugin.ps1`. Shared helpers live in `plugins/shared/`. Rust unit tests are colocated in `src/*.rs`; configuration fixtures live in `tests/fixtures/`. Use `examples/` for runnable configurations and `docs/adr/` for architectural decisions. Read `docs/plugin-authoring.md` before changing a plugin.

## Build, Test, and Development Commands

- `cargo build` — compile the development binary.
- `cargo test` — run all Rust unit tests.
- `cargo fmt --all -- --check` — verify Rust formatting; run `cargo fmt --all` to fix it.
- `cargo run -- plugins` — confirm plugin discovery, placements, and requirements.
- `cargo run -- schema --output winix-cfg.schema.json` — regenerate the composed schema.
- `cargo run -- validate examples/workstation.yaml` — perform schema and runtime validation.
- `cargo run -- plan examples/workstation.yaml --output trace` — inspect the closed operation queue without mutation.

Use `apply` only on a Windows test machine after reviewing the plan. System changes require `--system`; `--all` applies system state first.

## Coding Style & Naming Conventions

Use standard `rustfmt` output and Rust `snake_case` for modules, functions, and tests. PowerShell scripts use four-space indentation, `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, and approved Verb-Noun function names. Plugin manifest names are kebab-case; configuration paths and schema properties are lower snake case, such as `packages.windows_installer`. Format JSON with two-space indentation and keep schemas closed with `additionalProperties: false` where practical.

## Testing Guidelines

Add focused `#[test]` functions beside Rust code and name them by behavior, for example `rejects_ambiguous_case_insensitive_names`. Add minimal YAML fixtures for edge cases. Test convergence, empty plans, stale-plan rejection, idempotence, placement boundaries, and stdout cleanliness. No coverage threshold is defined.

## Commit & Pull Request Guidelines

Git history is not included in this checkout, so no established commit convention can be verified. Use short imperative subjects, optionally scoped, such as `plugins: verify AppX postconditions`. Keep commits focused. Pull requests should explain behavior and architectural impact, link relevant issues/ADRs, list validation commands run, and include plan or NDJSON excerpts when protocol behavior changes. Call out destructive operations, privilege changes, schema changes, and generated-file updates explicitly.

## Architecture & Safety

Preserve the protocol-v2 validate/plan/apply boundary. Planning is side-effect free; apply may execute only the exact planned operations after whole-queue preflight. Never mix incidental output into plugin stdout, which is a strict NDJSON stream ending in one result record. Keep user plugins unelevated and system mutations isolated to system placement.

Target the latest generally available Windows 11 Home release and its consumer-facing behavior unless a task explicitly requests broader compatibility. Windows Home is the baseline edition: do not depend on Pro/Enterprise-only Group Policy, MDM/CSP, domain, or organizational management surfaces. Do not add legacy Windows build branches or fallback registry mappings. Support for an active Windows Insider build may be added deliberately alongside the current generally available release when needed, preferably through capability detection rather than permanent version branches.

JSON object property order is not stable across the Rust/PowerShell protocol boundary. Never compare structured state by comparing `ConvertTo-Json` strings; this can falsely reject an unchanged plan after keys are reordered. Use the shared `Test-WinixJsonEqual` helper for JSON-semantic equality or compare explicitly named fields when the resource has stronger semantics. Regression checks for structured preconditions must include deliberately reordered properties.

PowerShell `ConvertFrom-Json` may deserialize ISO-8601 strings as `DateTime` objects. Do not use formatted timestamp strings as opaque plan/apply tokens; prefer content hashes or numeric time values, or normalize both sides explicitly and test them after a complete JSON round trip.
