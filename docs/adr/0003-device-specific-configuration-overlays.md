# ADR 0003: Device-specific configuration overlays

- Status: Accepted
- Date: 2026-07-19
- Decision owners: Winix maintainers

## Context

Winix configuration is intended to be synchronized through shared storage and reused across laptops and other primarily single-user Windows devices. Some desired state is common to every device, while hardware-dependent and host-specific settings must apply only to one device.

Device specificity is independent from the system/user execution boundary established by ADR 0002. A device can contain both machine-wide configuration and current-user configuration. Plugins should not register a third `device` placement or implement document overlay behavior themselves.

Display configuration motivates this distinction: general user preferences may be shared while resolution and monitor topology may differ by device. Display configuration itself is outside the scope of this ADR.

## Decision

### Document structure

The root document may contain a `devices` map keyed by Windows computer name:

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
        desktop:
          theme: dark

devices:
  development-laptop:
    system:
      packages:
        winget:
          laptop-utility:
            id: Vendor.LaptopUtility
            state: installed

    users:
      current:
        windows:
          personalization:
            taskbar:
              automatically_hide: true
```

Each device value has the same `system` and `users` structure available at the document root. Plugins retain their relative path and `system`/`user` placements. There is no `device` plugin placement.

### Device selection

The engine reads the local Windows computer name and matches it case-insensitively against keys beneath `devices`. At most one device key may match case-insensitively. Ambiguous keys such as `laptop` and `LAPTOP` in the same document are an error when that device is selected.

When no device matches, global configuration remains valid and is used without an overlay. The CLI reports the detected device and whether an overlay matched.

Manual selection of another device during apply is not supported initially. This prevents accidentally applying another host's hardware-specific configuration.

### Effective configuration

Before inspection or application, Rust constructs an effective document:

```text
global system + selected device system = effective system
global users  + selected device users  = effective users
```

Merging follows these rules:

- objects merge recursively;
- entries in named maps merge by key because they are objects;
- a device scalar replaces the corresponding global scalar;
- a device array replaces the corresponding global array;
- a device null replaces the corresponding global value;
- omitted device properties inherit global configuration.

The selected overlay is applied only in memory. The source document is not modified.

Explicit resource states, such as `state: absent`, are used when a device must countermand inherited desired state. A general deletion marker is deferred.

The source document is validated against the composed schema before merging. The effective document is also validated before plugin execution so that future merge rules cannot create an invalid plugin subtree.

### Schema composition

The generated JSON Schema reuses the composed system and user placement schemas beneath every arbitrary device key:

```text
system
users.current
devices.<computer-name>.system
devices.<computer-name>.users.current
```

Device names are configuration identities understood by the core. Plugins remain unaware of the device-map layout.

### Execution context

Plugin requests and aggregated results include the detected device name and the matched configuration key, if any. User and system selection continues to follow ADR 0002:

```text
apply           effective users.current only
apply --system  effective system only
apply --all     effective users.current, then effective system
```

Only the already-resolved effective system subtree crosses the UAC boundary. The elevated worker does not independently select or merge device configuration.

## Consequences

### Positive

- One synchronized document can serve multiple Windows devices.
- Global configuration remains concise while host-specific differences are localized.
- Device layering does not complicate plugin registration or PowerShell implementations.
- Existing user/system privilege separation remains intact.
- The model can later support device-specific display configuration without making monitors a core concept.

### Negative

- The engine now owns deterministic overlay semantics in addition to format parsing.
- Renaming a Windows computer stops its previous overlay from matching.
- Arrays cannot be extended through an overlay; they are replaced.
- A whole-document schema is larger because placement schemas also appear beneath device entries.

### Risks

- A misspelled device name silently results in global-only configuration unless clearly reported.
- Computer names are convenient but less stable than an explicit machine identity.
- Applying inherited destructive state may surprise users if the effective configuration is not inspectable.

## Deferred decisions

- Stable device IDs or explicit matching metadata in addition to computer names.
- Device groups, tags, roles, or multiple overlay inheritance.
- A CLI command that renders the complete effective configuration.
- Manual device selection for validation or preview.
- General deletion or “unmanage inherited value” merge markers.
- Config-file merging across multiple physical files.
- The user-scoped display and monitor configuration plugin.
