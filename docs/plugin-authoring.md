# Writing a Winix plugin (module)

Winix extensions are called **plugins** in the code, manifests, and protocol. A
plugin owns one configuration subtree and implements it in PowerShell. The word
"module" in this repository usually means a PowerShell module managed by the
`packages.powershell_modules` plugin, so new extensions should use *plugin* in
names and documentation.

This guide summarizes the current implementation and accepted architecture
decisions. When it conflicts with an accepted ADR, the ADR is authoritative.

## The contract at a glance

A plugin:

- lives in its own directory beneath `plugins/`;
- contains `plugin.json`, `schema.json`, and `plugin.ps1`;
- owns one unique dotted configuration path for one or both placements;
- accepts protocol-v2 `validate`, `plan`, and `apply` invocations;
- reads one JSON request from standard input;
- writes zero or more NDJSON events and exactly one final result to standard
  output;
- observes and plans without changing the machine;
- applies only the exact, ordered operations approved by the plan; and
- converges idempotently and verifies its postconditions.

The lifecycle is deliberately split across processes:

```text
schema validation
      |
      +-- validate (validation-only CLI commands)
      |
      `-- plan: runtime validation -> observe -> return closed operation queue
                                                    |
                         separate process           v
                     apply: preflight entire queue -> mutate -> verify
```

Do not rely on process memory surviving between phases. `plan` must include its
own runtime validation, because the engine does not invoke `validate` before a
normal plan. `apply` must re-observe all preconditions before its first mutation.

## 1. Design the resource contract first

Before writing PowerShell, decide the following.

### Windows support baseline

Target the latest generally available Windows 11 Home release and its consumer-facing behavior. Do not depend on Pro/Enterprise-only Group Policy, MDM/CSP, domain, or organizational-management surfaces, and do not add legacy Windows build branches or fallback registry mappings. An active Windows Insider build may be supported deliberately alongside the current generally available release; prefer capability detection over permanent build-number branches. See [ADR 0020](adr/0020-windows-support-baseline.md).

### Configuration path

Choose a lower-snake-case dotted path such as `windows.developer` or
`packages.windows_installer`. Every segment may contain only lowercase ASCII
letters, digits, and underscores.

Paths must be unique within a placement and cannot overlap. For example, a user
plugin at `windows.example` prevents another user plugin from owning
`windows.example.child`. Intermediate paths are namespaces composed by the Rust
host; a plugin owns only its leaf value.

### Placement and privilege boundary

Supported placements are:

| Manifest value | Configuration location | Execution context |
| --- | --- | --- |
| `system` | `system.<path>` | Elevated system worker during apply |
| `user` | `users.current.<path>` | Original interactive user, never elevated |

A dual-placement plugin receives the same schema at each location and must use
`request.context.scope` when behavior differs. If individual properties belong
to different placements, reject misplaced properties during runtime validation;
`windows.developer` is the current example.

Never obtain elevation inside a user plugin or try to manipulate another user's
profile. System and current-user ownership are intentionally separate, even when
both placements refer to a similarly named resource. `apply --all` completes the
system phase before planning and applying the user phase.

### Semantic resource identity

Use object-map keys as canonical resource identities when managing a collection.
The key should be the stable name used by the underlying system: a package ID,
MSI product code, AppX name, service name, feature name, or another documented
identity. Do not introduce a user-chosen alias plus a duplicate `id` property.

Define casing and normalization explicitly. Validate canonical identity at
runtime when JSON Schema cannot do so. If no natural string identity exists,
design a canonical composite identity or use a structure with explicit required
identity fields before treating overlay behavior as stable.

Device overlays merge objects recursively but replace scalars and arrays. A
semantic map therefore lets a device override one resource without replacing
the rest of the collection.

### Declarative and safe semantics

- Describe outcomes, not command lines, registry implementation details, or
  scripts supplied by configuration.
- Treat omitted properties as unmanaged unless the schema and docs explicitly
  say otherwise. A schema `default` is only an editor annotation.
- Require explicit destructive intent, normally `state: absent`.
- Reconstruct native commands from validated, typed operation data. Never put an
  executable command string in a plan or execute a command supplied by the user.
- Decide ownership before supporting removal. If the plugin cannot distinguish
  what it owns safely, defer removal or use receipts as `nerd-fonts` does.

## 2. Create the plugin directory

Use a domain-oriented directory; discovery is recursive, so directory names do
not define the configuration path.

```text
plugins/example/widget/
|-- plugin.json
|-- schema.json
`-- plugin.ps1
```

The shared helpers are in `plugins/shared/Winix.PluginSdk.psm1`.

### Manifest

Start with:

```json
{
  "protocol_version": 2,
  "name": "example-widget",
  "path": "example.widgets",
  "placements": ["user"],
  "entrypoint": "plugin.ps1",
  "schema": "schema.json",
  "requires": {
    "powershell": ">=7.0",
    "administrator": false,
    "commands": []
  }
}
```

`name` is a stable plugin identifier and also becomes the key for its schema in
the generated root schema. `entrypoint` and `schema` are relative to the plugin
directory. Use protocol version `2`.

The `powershell`, `administrator`, and `commands` fields currently document
runtime requirements and appear in `winix-cfg plugins`; the plugin still needs
to perform meaningful environmental checks. Placement controls the engine's
actual privilege boundary. Keep the manifest accurate even where the host does
not yet enforce the metadata.

If another Winix-managed resource is a prerequisite, declare desired
configuration relative to the current placement:

```json
"requires": {
  "powershell": ">=7.0",
  "administrator": false,
  "commands": [],
  "configuration": {
    "packages": {
      "powershell_modules": {
        "Example.Client": {
          "state": "installed",
          "repository": "PSGallery"
        }
      }
    }
  }
}
```

Winix merges this fragment into effective configuration without rewriting the
user's file, rejects conflicting explicit values, orders the provider before the
dependent during apply, and adds provider operation IDs to the dependent
operations' `data.depends_on` arrays. Requirements are placement-local and may
be transitive; cycles fail discovery.

Important: plugins still plan concurrently within a placement. A dependency
does not mean its provider has already planned or applied when the dependent
plans. If the dependency is needed for observation, retain a read-only bootstrap
observation path until the first prerequisite apply has completed.

### Schema

`schema.json` is a JSON Schema Draft 2020-12 schema for the value **at the
plugin's path**, not for the whole Winix document:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "Example widgets",
  "description": "Desired state for Example widgets.",
  "type": "object",
  "propertyNames": { "minLength": 1 },
  "additionalProperties": {
    "type": "object",
    "properties": {
      "state": {
        "type": "string",
        "enum": ["installed", "absent"],
        "default": "installed"
      }
    },
    "additionalProperties": false
  }
}
```

Prefer closed objects (`additionalProperties: false`). Add descriptions, enums,
patterns, and examples because the composed schema drives validation and editor
completion. Use schema constraints for portable document rules, then repeat or
extend critical checks at runtime for platform state, canonical catalog values,
Windows-version support, and placement-specific rules.

## 3. Implement the protocol entrypoint

Begin `plugin.ps1` with strict, noninteractive behavior and the shared SDK:

```powershell
param(
    [Parameter(Mandatory)]
    [ValidateSet('validate', 'plan', 'apply')]
    [string] $Operation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Winix.PluginSdk.psm1') -Force
$request = Read-WinixRequest
```

Adjust the relative SDK path for the plugin directory's depth. The host launches
PowerShell 7 with no profile and passes the operation as a positional argument.

The request contains:

| Field | Meaning |
| --- | --- |
| `protocol_version` | `2` |
| `plugin` | Stable manifest name |
| `path` | Absolute configuration path, including placement |
| `configuration` | Value selected at the plugin path |
| `context.scope` | `system` or `user` |
| `context.user_selector` | `null` or `current` |
| `context.device` | Resolved Windows computer name |
| `context.device_overlay` | Whether a matching device overlay was merged |
| `context.user_sid` | SID of the original interactive user, preserved across the elevated system worker |
| `context.elevated` | Current process elevation state |
| `context.dry_run` | Whether the engine is only inspecting |
| `context.prior_operations` | Earlier-scope operations, when applicable |
| `operations` | Exact approved queue; present only for `apply` |

Treat fields not guaranteed for an operation as optional. In particular,
`prior_operations` is planning context and is not present when consuming a saved
plan through every code path.

### Validate

`validate` performs environmental and placement-specific validation without
mutation. Return:

```powershell
Write-WinixResponse @{
    protocol_version = 2
    valid = $true
    diagnostics = @()
}
```

Validation failures should use structured diagnostics with stable codes,
human-readable messages, and configuration paths/help where useful. Also run
the required validation from `plan`; validation-only state is not shared.

### Plan

Planning must be side-effect free. Observe current state, resolve moving policy
such as `latest` to concrete values, and return a closed ordered queue:

```powershell
$operation = [ordered]@{
    id = 'example.widget.Sample.install'
    action = 'install'
    resource = [ordered]@{
        type = 'example.widget'
        id = 'Sample'
    }
    before = $null
    after = [ordered]@{ state = 'installed'; version = '1.2.3' }
    data = [ordered]@{
        version = '1.2.3'
        depends_on = @()
    }
}

Write-WinixResponse @{
    protocol_version = 2
    success = $true
    changed = $false
    state = $observedState
    operations = @($operation)
    diagnostics = @()
    restart_required = @{ explorer = $false; system = $false }
}
```

Every operation needs a nonempty, globally unique string `id`. Use a stable,
namespaced ID derived from the plugin/resource/action, not the queue index. It
also needs typed `action`, semantic `resource`, concrete `before` and `after`, and
an object-valued `data`. Include `data.depends_on` when the plugin itself has
known prerequisites; the engine may append manifest-derived prerequisites.

`changed` is false during planning because planning did not mutate anything.
`restart_required` may predict the consequence of consuming the queue. Return an
empty `operations` array when already converged; the engine then skips `apply`.

Observation is commonly the slowest step. Prefer one scope-wide inventory query
and an in-memory index over repeated point queries. Independent queries inside a
plugin can run concurrently, but never depend on another plugin's plan-completion
order. Avoid downloads and other expensive work unless they are required to
bind a concrete, verifiable artifact into the plan.

### Apply

Apply receives the exact planned queue in `$request.operations` and runs in a
new PowerShell process. Its obligations are stricter than ordinary idempotence:

1. Reject a missing operations field and unknown actions/resource types.
2. Re-observe and validate the preconditions for the **entire queue** before the
   first mutation. Fail a stale plan instead of refreshing it.
3. Execute only the supplied operations, once each, in their given order.
4. Build native commands from validated typed fields; never discover new work.
5. After each mutation, invalidate any affected observation cache and verify the
   desired postcondition in the correct placement.
6. Return the unchanged queue and account for operation IDs in exact order.

On success, return:

```powershell
Write-WinixResponse @{
    protocol_version = 2
    success = $true
    changed = ($appliedIds.Count -gt 0)
    state = $observedState
    operations = @($request.operations)
    applied_operation_ids = @($appliedIds)
    diagnostics = @()
    restart_required = @{ explorer = $false; system = $false }
}
```

The engine rejects a changed/reordered operation queue and any missing, extra,
non-string, or reordered applied ID. Apply is not transactional: if a later
operation fails, report completed IDs and stop. A future plan will observe the
partial state. Do not attempt an unsafe generic rollback.

For external installers, verify registered post-install state rather than
assuming process exit means convergence. A process can succeed yet install into
the wrong scope. Report that as a changed failure; do not silently remove the
wrong-scope installation unless removal was independently planned.

## 4. Events, diagnostics, and output discipline

Use `Write-WinixEvent` for incremental, structured progress and
`Write-WinixResponse` exactly once for the authoritative result:

```powershell
Write-WinixEvent `
    -Kind 'resource_checking' `
    -ResourceType 'example.widget' `
    -ResourceId 'Sample' `
    -Data @{ phase = 'plan' }
```

Useful event kinds are `resource_checking`, `resource_status`,
`resource_change_started`, `resource_change_completed`, `progress`, and
`diagnostic`. Resource events should carry the semantic resource type and ID.
Diagnostics should have stable machine-readable codes and structured data;
messages are for people and may evolve. Never place secrets in either.

Standard output is a strict NDJSON protocol. Accidental output from cmdlets,
native commands, `Write-Output`, progress streams, or imported modules can make
the entire invocation fail. Capture or redirect command output and put intended
information in events. Standard error is reserved for unexpected process-level
details and is truncated when surfaced by the host. Do not emit ANSI styling or
terminal layout.

The result must be the final stdout record. Malformed JSON, unknown record
types, duplicate results, output after the result, a missing result, or a nonzero
exit status is a protocol failure.

## 5. Verification workflow

Use a small fixture under `tests/fixtures/` or an example configuration that
exercises both converged and change-required paths. Then run:

```powershell
# Confirm discovery, path, placements, and displayed requirements.
cargo run -- plugins

# Compose every plugin schema and catch path/schema collisions.
cargo run -- schema --output winix-cfg.schema.json

# Check document schema plus runtime validation.
cargo run -- validate path/to/fixture.yaml

# Exercise observation and inspect the result without mutation.
cargo run -- inspect path/to/fixture.yaml --output ndjson

# Inspect the concrete queue and event timing.
cargo run -- plan path/to/fixture.yaml --output trace

# Run Rust checks after host/discovery changes.
cargo test
```

Use `--system` or `--all` where the fixture contains system configuration. Only
run `apply` on a disposable/test machine after reviewing the complete plan.
Test at least:

- invalid schema input and environmental validation failures;
- a converged plan with no operations;
- a concrete change plan;
- stale-plan rejection before any mutation;
- postcondition failure and partial-apply accounting;
- repeated apply/idempotence;
- each declared placement and wrong-placement rejection;
- device overlay merging for resource maps; and
- stdout cleanliness when native tools produce output.

## Common gotchas

- **A plan is not a preview-shaped apply.** It must not create directories,
  install prerequisites, update caches on disk, or otherwise prepare the host.
- **`validate` is not guaranteed to run before `plan`.** Share validation
  functions, not process state.
- **Apply is a new process.** Carry every concrete decision in typed operation
  fields and re-observe preconditions.
- **Preflight covers the whole queue.** Checking just before each mutation can
  leave half a queue applied when a later precondition was already stale.
- **Plans are closed.** Apply cannot silently re-plan, append work, substitute a
  new `latest`, or skip an approved operation because it now looks converged.
- **Dependencies do not serialize planning.** Same-placement plans run in
  parallel and their events may interleave.
- **System and user resources are distinct.** An absence declaration affects
  only its placement unless the plugin's documented system semantics explicitly
  own all users, as AppX does.
- **Manifest requirements are not a substitute for checks.** Most requirement
  metadata is currently descriptive; `requires.configuration` is the part used
  to build managed dependencies.
- **Schema defaults do not manage omitted values.** Test property presence with
  `Test-WinixPropertyPresent` rather than relying on truthiness or a default.
- **Test omission independently from false.** For each optional property, cover
  an omitted value with a configured sibling and, for booleans, an explicit
  `false`. The omitted case must not appear in observed state or planned
  operations. Any documented collection-level ownership exception needs its own
  exhaustive-set regression test.
- **PowerShell null/array behavior is sharp.** Wrap protocol collections with
  `@(...)`, preserve ordered arrays, and test zero-, one-, and many-item cases.
- **JSON object property order is not stable across the protocol boundary.**
  Rust JSON serialization can reorder object keys between plan and apply. Never
  compare state by testing two `ConvertTo-Json` strings for equality: identical
  objects with different key order will produce a false stale-plan failure. Use
  `Test-WinixJsonEqual` from the shared SDK for JSON-semantic equality, or compare
  explicitly named fields when the resource has stronger semantics (for example,
  sorting a set-valued file list). Add a regression case with deliberately
  reordered properties whenever structured state participates in preflight.
- **ISO-8601 strings may not remain strings.** PowerShell's `ConvertFrom-Json`
  can deserialize date-shaped JSON strings as `DateTime` values. Avoid using a
  formatted timestamp as an opaque precondition token. Prefer a content digest,
  an integer epoch/tick value, or explicit normalization on both sides, and test
  the value after a full JSON serialize/deserialize round trip.
- **Native command success is not the postcondition.** Re-observe using the
  authoritative scope-aware source after invalidating cached state.
- **Do not use unsafe inventory providers.** For example, the MSI plugin avoids
  `Win32_Product` because querying it can trigger repair actions.

## Good examples to copy

- `plugins/windows/personalization/start-menu`: small property-oriented plugin
  with a readable closed plan and whole-queue stale check.
- `plugins/packages/windows-installer`: system-only semantic identity and safe
  absence behavior.
- `plugins/packages/appx`: one plugin with deliberately different user/system
  observation and ownership semantics.
- `plugins/packages/winget`: required configuration, concrete version planning,
  cross-scope rules, and provider postcondition verification.
- `plugins/fonts/nerd-fonts`: artifact pinning, digest verification, receipts,
  and ownership-safe removal.

Relevant decisions are [ADR 0001](adr/0001-core-architecture-and-initial-modules.md),
[ADR 0002](adr/0002-system-and-user-configuration-boundaries.md),
[ADR 0005](adr/0005-semantic-resource-map-keys.md),
[ADR 0006](adr/0006-structured-operation-event-stream.md),
[ADR 0007](adr/0007-system-first-privilege-isolated-apply.md),
[ADR 0009](adr/0009-closed-plan-and-apply-operation-queue.md),
[ADR 0011](adr/0011-plugin-required-configuration.md), and
[ADR 0015](adr/0015-parallel-plugin-planning.md). Domain-specific plugin ADRs
are useful examples but do not replace these cross-plugin contracts.
