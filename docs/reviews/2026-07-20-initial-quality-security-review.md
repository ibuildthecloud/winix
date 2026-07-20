# Initial quality and security review

- Date: 2026-07-20
- Scope: Rust core, PowerShell plugin system, configuration schemas, examples, tests, documentation, build and release practices
- Baseline: latest generally available Windows 11 Home
- Status: accepted as the initial quality-improvement work program

## Product decision

Winix should evolve its current architecture rather than be rewritten. The protocol-v2 validate/plan/apply boundary, scoped plugin model, composed schemas, strict NDJSON output, and explicit desired-state configuration are the right foundation.

`apply` is the primary supported product workflow. It is not treated as a secondary or experimental command. Because Winix is pre-1.0, confidence in apply must come from enforced invariants, regression tests, clean-machine validation, and honest release notes. The plan below raises those guarantees without weakening the product's purpose.

## Existing strengths

- The validate/plan/apply lifecycle and user/system placement boundaries are explicit and well documented.
- Apply uses a closed operation queue and verifies returned operation identities.
- Configuration is opt-in, schemas are generally closed, and destructive intent such as `state: absent` is explicit.
- Plugin stdout is a strict NDJSON protocol rather than a mixed human/machine stream.
- Shared JSON comparison uses semantic equality, avoiding object-property-order bugs across Rust and PowerShell.
- Many plugins already perform whole-queue preflight, mutation, and postcondition verification as separate phases.
- The repository contains substantial ADR and plugin-authoring guidance.

## Priority findings

### P0 — Release safety and trust boundaries

1. **Elevated code provenance is not yet strongly bound.** Repository builds enable working-directory plugin discovery by default; PowerShell can be selected through `WINIX_PWSH` or `PATH`; several plugins invoke native tools by name. A manifest, schema, entrypoint, runtime, or native executable can change between planning and elevated apply without a bundle digest proving it is the code that produced the reviewed queue.
2. **Placement isolation is incomplete during validation.** Starting Winix elevated can cause a user-placement plugin's validation entrypoint to run with the elevated caller token, contrary to the design rule that user plugins remain unelevated.
3. **Whole-queue preflight is not uniformly implemented.** ARP, Windows Installer, WSL, and system AppX contain paths that validate or observe state immediately before each mutation instead of proving every queued precondition before the first mutation. ARP can also execute an uninstall command re-read after planning rather than the exact approved invocation.
4. **Some modeled outcomes conflict with the Windows 11 Home baseline.** Taskbar layout, Widgets, Edge, Search, and Remote Desktop configuration rely on policy or edition-specific mechanisms that can make registry/file state look converged without proving the consumer-facing result on Home.

### P1 — Protocol, supervision, and correctness

1. Core plugin results and operations remain largely untyped JSON. Missing or incorrectly typed success, dependency, and operation fields can fail open instead of being rejected at the process boundary.
2. Plan dependency validation can use JSON object iteration instead of topological plugin order, and dependency association uses suffix matching that can collide for nested plugin paths.
3. Elevated request/result transport uses ordinary command-line and temporary-file mechanisms without an authenticated per-operation channel, restrictive object creation, or reparse-point defenses.
4. Plugin processes have no deadline, output-size bound, global concurrency cap, or process-tree cancellation policy. Event sink failures are discarded, and some failures do not emit a terminal `operation_failed` event.
5. Duplicate plugin names, manifest path containment, native executable identity, and engine-reserved event kinds need explicit validation.
6. Targeted plugin defects include WinGet dependency bootstrap timing, an unpinned WSL `latest` update at apply, Nerd Fonts receipt-path containment, and registry value comparisons that can conflate value type.

### P2 — Maintenance and release engineering

1. The Rust core is concentrated in several large modules and passes raw JSON through core planning logic. Extracting typed protocol and platform seams will make isolated testing practical.
2. Automated assurance covers only a small portion of the 25 PowerShell plugins. The YAML fixtures are not yet executable tests, and there is no Pester contract suite.
3. The initial checkout had no CI, pinned toolchain/MSRV, dependency-policy tooling, signed bundle, SBOM, or documented release process.
4. `serde_yaml` resolves to a deprecated implementation, while `jsonschema` default features enable unused external resolution and HTTP dependencies. Dependency advisories were not established during the review because the relevant audit tool was unavailable.
5. Documentation has duplicate ADR numbers and an incomplete plugin summary. Automatic PowerShell runtime installation also makes some nominally read-only commands mutate the host and should become an explicit or lazy provisioning action.

## Baseline evidence

The initial review ran the following checks before remediation work began:

| Check | Result |
| --- | --- |
| `cargo fmt --all -- --check` | Passed |
| `cargo test --all-targets --all-features` | 39/39 passed |
| `cargo test --all-targets --no-default-features` | 39/39 passed |
| `cargo build --release --no-default-features` | Passed with one dead-code warning |
| Strict Clippy (`-D warnings`) | Failed with five diagnostics |
| Plugin discovery | All 25 manifests discovered |
| Generated root schema | Byte-for-byte reproducible in the review environment |
| Example validation and user plan | Passed |
| PSScriptAnalyzer 1.25 | 47 warnings, including automatic-variable assignments |
| Dependency advisory scan | Not established; audit tooling was not installed |

The test suite at that point contained only two Windows-gated Rust tests that executed real plugins, no Pester suite, and 17 YAML fixtures that were not invoked by automated tests.

## Delivery plan

### Phase 0 — Safety baseline and repeatable gates

- Replace the destructive copy-and-paste Quick Start with a narrow non-destructive configuration; retain opinionated examples under conspicuous warnings.
- Initialize the public repository and add Windows CI for Rust formatting, strict Clippy, locked tests in both feature modes, schema reproducibility, plugin discovery, examples, PowerShell analysis, and embedded C# compilation.
- Record a pinned Rust/MSRV policy and a PSScriptAnalyzer policy, including intentional suppressions rather than unexplained warnings.
- Add regression tests that reproduce plan-ordering, malformed protocol, stale-later-operation, structured terminal-event, JSON key-order, and elevated-validation defects.
- Check in the generated root schema and enforce regeneration in CI.

### Phase 1 — Privilege and plan integrity

- Make installed, administrator-owned plugin paths the production default and require explicit development-path opt-in.
- Prevent elevation of user-writable development plugins by default.
- Canonicalize and verify PowerShell and native executable identities; sanitize the elevated worker environment.
- Bind configuration, ordered plan, plugin bundle, and runtime digests across discovery, planning, elevation, and apply.
- Run user placement through a verified limited token even when validation begins elevated.
- Replace command-line/temp-file worker transport with an access-controlled, authenticated per-operation channel.
- Resolve or remove outcomes that cannot be verified on the supported Windows 11 Home consumer surface.

### Phase 2 — Typed protocol and uniform apply semantics

- Introduce typed request, result, event, operation, scope, restart, and error envelopes with strict required core fields.
- Preserve the explicit topological plan order and use exact plugin identities for dependency lookup.
- Centralize two-pass whole-queue preflight, mutation, postcondition, and structured failure handling in shared PowerShell support.
- Correct the identified ARP, MSI, AppX, WSL, WinGet, Nerd Fonts, registry, manifest, and executable-resolution defects.
- Add deadlines, bounded I/O, cancellation/process-tree handling, fallible event sinks, and exactly one terminal event per started operation.

### Phase 3 — Testability and maintainability

- Introduce a library boundary and separate protocol, planning, catalog, events, process supervision, and Windows platform code from the CLI.
- Inject filesystem, environment, process, elevation, identity, time, and plugin-runner seams.
- Build Pester 5 contract/provider tests for every plugin.
- Turn every fixture into an executable test and cover invalid input, reordered JSON, empty and converged plans, stale plans, postcondition failure, idempotence, placement, privilege, reboot, and stdout cleanliness.
- Add disposable Windows 11 Home VM convergence tests.

### Phase 4 — Release provenance

- Build a versioned binary/plugin/schema bundle from protected CI.
- Publish checksums and an SBOM and sign artifacts with a protected project identity.
- Enforce dependency advisory, license, and source policies.
- Document upgrade, recovery, reboot, destructive-operation, and compatibility behavior in each release.

## Definition of done for a production-quality release

- Formatting, strict static analysis, locked tests, schema regeneration, plugin contracts, and Windows VM scenarios pass in CI.
- No elevated process loads code or an executable from a user-writable or unverified location.
- The reviewed ordered plan is cryptographically bound to the configuration, plugin bundle, runtime, and applied queue.
- Every plugin proves the entire queue's preconditions before the first mutation and verifies every postcondition afterward.
- Every started operation has one structured terminal event; process failure, timeout, cancellation, and output overflow fail closed.
- On a clean supported Windows 11 Home VM, first apply converges, second apply is empty, and a deliberately stale plan causes zero mutation.
- Destructive behavior, schema changes, privilege changes, and generated artifacts are explicit in release notes.
