# ADR 0005: Semantic resource map keys

- Status: Accepted
- Date: 2026-07-19
- Decision owners: Winix maintainers

## Context

Winix uses named object maps for collections of declaratively managed resources. Object keys become merge identities when global, device-specific, and eventually multi-file configuration layers are combined.

The initial WinGet syntax used an arbitrary user-selected key plus the actual package ID in an `id` property:

```yaml
packages:
  winget:
    vscode:
      id: Microsoft.VisualStudioCode
      state: installed
```

Two documents could call the same package `vscode` and `code`, causing the merge engine to treat one package as two resources. Conversely, the same arbitrary key could refer to different IDs in different layers. Both outcomes make overrides unreliable.

WinGet IDs are case-sensitive canonical identifiers for configuration purposes even where lookup behavior may accept case-insensitive or partial input. Case variants also remain distinct JSON object keys and would therefore produce incorrect merges.

## Decision

Keys in resource maps must be stable, domain-meaningful identities for the resources they represent. Arbitrary user-selected aliases must not be used as merge identities.

The WinGet package ID becomes the map key:

```yaml
packages:
  winget:
    Microsoft.VisualStudioCode:
      state: installed

    Git.Git:
      state: installed
```

The redundant `id` property is removed. Optional descriptive text belongs in a non-identifying property and does not participate in merging.

The WinGet plugin resolves every configured key through WinGet during runtime validation. It requires an exact case-sensitive match with the canonical ID returned by the configured source. Incorrect case, partial IDs, and aliases are validation errors. When WinGet resolves the input to a different canonical ID, the diagnostic includes that ID as a suggestion.

`winix-cfg validate` performs both portable JSON Schema validation and non-mutating plugin runtime validation. Runtime validation may inspect installed tools and external catalogs but must not require elevation or modify state.

Plugin schemas must document the meaning and expected format of dynamic resource keys. Plugins should reject duplicate identities according to domain comparison rules even when the underlying configuration format considers their keys distinct.

When a resource has no natural single-string identity, its plugin must define a canonical composite identity or use another structure with explicit required identity fields. Identity design is part of the plugin contract and must be decided before merge behavior is considered stable.

## Consequences

### Positive

- Global and device overlays reliably identify the same package.
- Package declarations are shorter and cannot contain conflicting key and `id` values.
- Casing mistakes are caught before inspection or application.
- The rule provides consistent guidance for future service, feature, environment, file, registry, task, and display resources.

### Negative

- Users must use exact canonical WinGet IDs as YAML, JSON, or TOML keys.
- Runtime validation requires WinGet catalog access and is slower than schema-only validation.
- Canonical validation depends on parsing current WinGet human-readable output until a stable structured output is available.
- Some future resources may require more complex composite identities.

## Examples

Likely semantic identities include:

| Resource | Map identity |
| --- | --- |
| WinGet package | Canonical package ID |
| Windows service | Service name |
| Environment variable | Variable name within its scope |
| Optional Windows feature | Feature name |
| File | Canonical target path |
| Scheduled task | Canonical task path and name |

These examples guide later plugin ADRs but do not finalize their schemas.
