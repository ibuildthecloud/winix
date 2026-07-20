# ADR 0002: System and user configuration boundaries

- Status: Accepted
- Date: 2026-07-18
- Decision owners: Winix maintainers
- Supersedes: The unscoped initial plugin paths in ADR 0001

## Context

`winix-cfg` manages both machine-wide Windows state and state belonging to Windows user profiles. Machine configuration normally requires an administrator token, while current-user personalization should run without elevation in the interactive user's session.

Configuration should remain one coherent document, but system and user declarations must not be mixed at arbitrary resource levels. Privilege is an execution concern and should not be repeated as configuration on individual settings or packages.

Windows elevation creates an important identity boundary. The account that approves a UAC prompt may differ from the interactive user that launched `winix-cfg`. User configuration must therefore never be applied by assuming that an elevated process's `HKCU` identifies the intended user.

The phrase “all users” is ambiguous on Windows: it may refer to existing local profiles, the default profile used for future users, domain users without local profiles, or machine policy. The first implementation needs an unambiguous current-user model without preventing later support for those cases.

## Decision

### Unified document with structural boundaries

A configuration document may contain both `system` and `users` sections:

```yaml
version: 1

system:
  packages:
    winget:
      powershell:
        id: Microsoft.PowerShell
        state: installed

users:
  current:
    windows:
      personalization:
        taskbar:
          alignment: left
```

Everything beneath `system` is machine-wide desired state. Everything beneath `users.<selector>` is desired state for the selected user profile. Individual resources will not contain `scope`, `privileged`, or `elevated` flags.

The first version supports only the reserved user selector `current`. It means the interactive user who launched the original `winix-cfg` process. Other user keys are rejected by the generated schema.

The names `existing`, `default`, and `named` are reserved for possible future selectors. Their behavior is deferred because applying configuration to loaded profiles, offline profile hives, future profiles, and policy are distinct operations.

### Plugin placement

A plugin manifest defines a relative configuration path and the placements in which it is valid:

```json
{
  "name": "winget",
  "path": "packages.winget",
  "placements": ["system", "user"]
}
```

Rust projects that registration into `system.packages.winget` and `users.current.packages.winget` when composing the root schema and routing configuration.

Personalization plugins support only user placement:

```json
{
  "name": "windows-taskbar",
  "path": "windows.personalization.taskbar",
  "placements": ["user"]
}
```

The core owns placement and selector syntax. PowerShell plugins receive their relative configuration subtree and an engine-supplied execution context. They do not parse the root document.

### Schema composition

The generated root JSON Schema contains independently composed system and user schemas. The system schema contains only plugins supporting `system`; the schema for `users.current` contains only plugins supporting `user`.

Unknown user selectors and plugins placed in an unsupported section are validation errors. The schema continues to provide IDE completion for the complete unified document.

### Apply selection

The `apply` command supports three modes:

```text
winix-cfg apply <config>           Apply users.current only
winix-cfg apply <config> --system  Apply system only
winix-cfg apply <config> --all     Apply users.current, then system
```

`--system` and `--all` are mutually exclusive. Defaulting to current-user application guarantees that an unqualified apply does not prompt for elevation or change machine-wide state.

A missing selected section is a successful no-op. The entire document is schema-validated before any selected section is applied.

### Execution and elevation

User plugins always execute in the original unelevated process as the current interactive user. They are never sent to the elevated system worker.

System apply is executed by an elevated copy of `winix-cfg`. If the coordinator is not elevated, it requests elevation through Windows UAC once and sends the worker a bounded request containing only the validated system subtree and the resolved plugin directory. The worker rejects execution unless it has an administrator token.

PowerShell plugins discovered from that directory execute with process-local `ExecutionPolicy Bypass`. The elevated identity can have a different effective script policy from the interactive user, and Winix plugins are already executable code admitted through plugin discovery. This does not modify persisted user or machine execution policy; plugin directory trust and signing remain installation concerns.

For `--all`, the engine requests elevation once, then the elevated worker plans and applies system configuration. Only after successful system completion does the original coordinator plan and apply current-user configuration unelevated. A rejected or failed elevation leaves user configuration untouched; rollback of completed system changes after a later user failure is outside the current design.

`system` means machine-wide configuration. It does not mean the Windows `LocalSystem` account. The initial elevated worker runs as the administrator identity produced by UAC.

The engine supplies protocol context such as:

```json
{
  "scope": "system",
  "user_selector": null,
  "elevated": true,
  "dry_run": false
}
```

or:

```json
{
  "scope": "user",
  "user_selector": "current",
  "elevated": false,
  "dry_run": false
}
```

Plugins must use this trusted context rather than accepting scope or elevation requests from their configuration subtree.

### Inspection

Inspection remains non-mutating and does not automatically elevate in this decision. Current-user inspection is the default. Expanded inspection selection and read-only elevated inspection may be added later.

## Consequences

### Positive

- One document can describe the complete computer without mixing scope at individual resources.
- Default apply is safe for routine use and never changes system state.
- User personalization runs against the correct interactive profile.
- System changes cross one visible UAC boundary.
- Plugin schemas and implementations can be reused across supported placements.
- Unsupported placements are rejected before plugin execution.

### Negative

- Applying the whole document is not atomic across the user and system boundary.
- The core must compose two related schema trees and route the same plugin at multiple absolute paths.
- The elevated worker and coordinator require a versioned request contract.
- Named, existing, default, and domain-user profile management remain unsupported.

### Risks

- A development-mode plugin directory supplied by an unelevated process is not yet a hardened trust boundary. Plugin installation, signing, and trusted discovery locations require a later ADR before third-party plugins are considered safe for elevation.
- UAC may be rejected or may use another administrator identity.
- A plugin may incorrectly treat machine scope as permission to operate on the elevated identity's user profile. Protocol assertions and tests should prevent this.

## Deferred decisions

- Existing-user, named-user, default-profile, and future-user selectors.
- Policy configuration that affects users machine-wide.
- Hardened authenticated IPC between the coordinator and elevated worker.
- Plugin signing and trusted installation directories.
- Rollback across user and system batches.
- Selection flags for `inspect` and other future operations.
