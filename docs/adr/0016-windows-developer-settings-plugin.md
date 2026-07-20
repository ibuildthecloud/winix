# ADR 0016: Windows developer settings plugin

- Status: Accepted
- Date: 2026-07-19
- Decision owners: Winix maintainers

## Context

Developer-oriented Windows configuration spans privilege scopes. Sudo for Windows is machine-wide and requires elevation. The taskbar End Task toggle belongs to the interactive user.

Microsoft documents `sudo config --enable <mode>` as the supported programmatic configuration interface. Microsoft's Sudo source defines its machine setting values, allowing side-effect-free observation without parsing localized CLI text. The taskbar End Task toggle has no documented CLI, CSP, public WinRT API, or Group Policy. `TaskManager/AllowEndTask` is not equivalent: it controls whether non-administrators may end tasks inside Task Manager.

## Decision

The `windows-developer` plugin registers at `windows.developer` for system and user placements. `sudo` is accepted only at system scope; `end_task` is accepted only at user scope.

Sudo mutation uses the supported `sudo.exe config --enable` interface and supports `force_new_window`, `disable_input`, and `inline`. Observation reads the setting contract implemented by Microsoft's open-source Sudo command.

End Task uses a narrowly isolated adapter for the per-user Windows setting store because no supported programmatic interface exists. This is explicitly a compatibility boundary, not a policy substitute. The adapter verifies the resulting value and can be replaced if Microsoft publishes an API.

## Consequences

- Sudo is configured through Microsoft's supported CLI and remains privilege-isolated.
- End Task is declarative but depends on an undocumented Windows setting-store contract.
- The plugin rejects settings placed in the wrong privilege scope.
