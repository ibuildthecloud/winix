# Winix

[![CI](https://github.com/ibuildthecloud/winix/actions/workflows/ci.yml/badge.svg)](https://github.com/ibuildthecloud/winix/actions/workflows/ci.yml)

`winix-cfg` is the declarative Windows configuration component of Winix. The Rust CLI loads and validates configuration, discovers path-based plugins, and supervises PowerShell 7 plugin execution. PowerShell plugins inspect and configure Windows.

Winix is pre-1.0 and under active development. `apply` is its primary workflow: every apply first produces a closed operation queue and runs plugin preflight and postcondition checks around that queue. Use `plan` to review the concrete operations whenever a configuration is new to you.

PowerShell 7 is a core Winix runtime. At startup Winix uses `WINIX_PWSH` when provided, then searches for an existing compatible `pwsh`. If none is available, the Rust host directly installs the latest `Microsoft.PowerShell` package through WinGet and verifies the resulting runtime before loading plugins. This bootstrap is runtime provisioning rather than managed configuration and is therefore outside the configuration plan.

## Quick start

```powershell
cargo run -- plugins
cargo run -- schema --output winix-cfg.schema.json
cargo run -- validate examples/quickstart.yaml
cargo run -- inspect examples/quickstart.yaml
cargo run -- plan examples/quickstart.yaml --user
cargo run -- apply examples/quickstart.yaml --user
```

The quick-start configuration is deliberately narrow: it manages only whether desktop icons are visible for the current user. It does not install or remove software, remove shortcuts, or require elevation. Reapplying it is convergent and should produce an empty plan after the setting reaches the desired state.

> [!CAUTION]
> [`examples/workstation.yaml`](examples/workstation.yaml) is a destructive, opinionated workstation profile. It removes AppX packages including Microsoft Store, removes shortcuts and OEM pin declarations, and replaces selected desktop, Start, and taskbar preferences. Read its complete plan before applying it; it is not the quick-start configuration.

Plan or apply a specific scope explicitly:

```powershell
# Force users.current only, even from an elevated terminal.
cargo run -- apply .\my-config.yaml --user

# Force system only, requesting UAC elevation when needed.
cargo run -- apply .\my-config.yaml --system

# Force system first, then users.current at limited privilege.
cargo run -- apply .\my-config.yaml --all
```

Unqualified `plan` and `apply` select `users.current` when Winix starts unelevated, and select system followed by `users.current` when Winix starts elevated. `--user`, `--system`, and `--all` override that default. An unelevated `--system` or `--all` requests UAC for the system phase; an elevated user phase runs in a verified same-user, same-session limited worker. Empty system configuration skips UAC.

Runtime validation and per-scope planning use the same concurrent plugin runner. Standalone validation runs configured user and system plugins together. Every apply first builds a closed operation queue; within each scope, all selected plugins plan concurrently. System scope is still completed before user scope so cross-scope migrations remain deterministic. Apply stays ordered and plugins may execute only their queued operations. Use `plan` with the same `--system` or `--all` selection as `apply` to inspect concrete changes without mutation. Policies such as WinGet `version: latest` resolve to an exact version during planning.

Plugins may declare required Winix configuration in their manifests. Winix merges those fragments into the effective configuration, rejects conflicts with explicit configuration, collects all plugin plans, and makes provider operation IDs prerequisites of dependent operations before apply. The user configuration file is not rewritten. Planning remains side-effect free; a provider that needs a bootstrapped dependency must retain an observation fallback until the first prerequisite apply completes.

The configuration argument is optional. Without one, `winix-cfg` uses `WINIX_CONFIG` when set and otherwise loads `%APPDATA%\Winix\config.yaml`:

```powershell
winix-cfg validate
winix-cfg inspect
winix-cfg apply
winix-cfg apply --user
winix-cfg apply --system
winix-cfg apply --all
```

Operations emit structured events. Console rendering is the default; NDJSON provides one enriched engine event per line for automation and future GUI integration:

```powershell
winix-cfg validate --output console
winix-cfg inspect --output ndjson
winix-cfg plan --all --output trace
winix-cfg apply --output ndjson
```

PowerShell plugins stream NDJSON event records followed by exactly one authoritative result record. Rust validates and enriches them with operation ID, sequence, timestamp, plugin path, scope, and device context before dispatching them to the selected renderer. The `trace` renderer emits the same raw NDJSON event with `elapsed_ms` and `delta_ms` fields for performance analysis.

Plugin resolution uses `--plugins-dir`, then `WINIX_PLUGINS`, then its compile-time default. Repository builds enable the `development-paths` feature by default and use `./plugins`. A production-oriented build uses `%ProgramFiles%\Winix\plugins`:

```powershell
cargo build --release --no-default-features
```

Configuration may be JSON, YAML, or TOML. All formats are normalized to a JSON-compatible object and validated against a JSON Schema composed from the discovered plugins. Machine-wide declarations live beneath `system`; current-user declarations live beneath `users.current`. Other user selectors are reserved for later versions.

The generated [`winix-cfg.schema.json`](winix-cfg.schema.json) is checked in so editors and examples work from a fresh clone. Plugin manifests and schemas are its sources of truth. Regenerate it after any schema change and commit it with the source change; CI rejects a generated schema that differs from the checked-in copy.

Device-specific configuration can overlay either tree. Keys beneath `devices` match the Windows computer name case-insensitively:

```yaml
users:
  current:
    windows:
      personalization:
        desktop:
          icons: disabled
          color: "#1E1E1E"

devices:
  development-laptop:
    users:
      current:
        windows:
          personalization:
            taskbar:
              automatically_hide: true
```

Objects merge recursively. Device scalar and array values replace global values. When no device key matches, only global configuration applies.

Configuration is opt-in at the property level. An omitted plugin path is not
run, and an omitted property inside a configured plugin is unmanaged: Winix
does not observe, plan, or change that setting. Boolean `false` is an explicit
managed value, not the same as omission. JSON Schema `default` values are editor
annotations and are not inserted into configuration. Resource entries may
document concise defaults of their own—for example, omitted `state` means
`installed` for WinGet packages, PowerShell modules, and Nerd Fonts. WSL also
documents resolver defaults and its additive distribution list in its schema.

## Selected plugin paths

| Relative path | Placements | Purpose |
| --- | --- | --- |
| `applications.windows_terminal` | user | Default profile, dynamic-profile sources, keybindings, profile visibility and appearance, and tab-switcher behavior |
| `fonts.nerd_fonts` | system, user | Install font families from official Nerd Fonts releases |
| `packages.powershell_modules` | system, user | Install or remove PowerShell modules with PSResourceGet |
| `packages.winget` | system, user | Install, upgrade, or remove WinGet packages |
| `applications.microsoft_edge` | system | Machine policies and required Microsoft Edge Add-ons |
| `windows.multitasking` | user | Alt+Tab application and tab behavior |
| `windows.wsl` | system | Install, upgrade, or remove WSL and install online-catalog distributions |
| `windows.personalization.desktop` | user | Desktop icon visibility and solid background color |
| `windows.personalization.screen_saver` | user | Enable or disable the current user's screen saver |
| `windows.personalization.start_menu` | system, user | Start menu preferences, folders, and scoped shortcut removal |
| `windows.personalization.taskbar` | user | Taskbar and selected system tray preferences |

Required Edge extensions are keyed by their canonical 32-character Microsoft
Edge Add-ons ID. Edge installs them silently and prevents the user from disabling
or uninstalling them. Extension-owned settings are not managed unless the
extension publishes a managed-storage schema; Winix does not edit Edge profile
storage directly:

```yaml
system:
  applications:
    microsoft_edge:
      extensions:
        onagfgjlokaciajhjmajljcfanonbmia:
          state: required
```

Use `windows.multitasking.alt_tab: windows_only` to show each application window
once in Alt+Tab instead of including individual tabs from supported applications:

```yaml
users:
  current:
    windows:
      multitasking:
        alt_tab: windows_only
```

Windows Terminal selectors use `guid:`, `name:`, or `source:` prefixes. Winix
resolves the default profile to its generated GUID, updates matching profile
entries, and owns only actions whose IDs begin with `Winix.`. Other Terminal
settings and generated profiles are preserved. If `key_bindings` is present,
its map is the complete desired set of `Winix.`-owned actions, so an omitted
Winix-owned action is removed. Configured key combinations take precedence over
an existing binding for the same keys:

```yaml
users:
  current:
    applications:
      windows_terminal:
        default_profile: source:Windows.Terminal.PowershellCore
        disabled_profile_sources: [Windows.Terminal.Azure]
        tab_switcher_mode: none
        graphics_api: direct3d11
        key_bindings:
          copy: { id: Terminal.CopyToClipboard, keys: ctrl+c }
          paste: { state: absent, keys: ctrl+v }
          previous_tab: { id: Terminal.PrevTab, keys: shift+left }
        profiles:
          defaults:
            font: { face: JetBrainsMono NFM, size: 12 }
            cursor_shape: filledBox
            bell_style: none
          overrides:
            name:Windows PowerShell: { hidden: true }
```

On Windows 11, `windows.personalization.taskbar.slots.apps` accepts one to five apps in taskbar order. Set `exhaustive: true` to remove every unlisted pin and make the entries the targets for Win+1 through Win+5. With `false`, Windows retains other pins, so earlier pins can affect the Win+number positions. Prefer portable aliases such as `windows_terminal`, `jetbrains_toolbox`, and `microsoft_edge`; raw AUMIDs, desktop application IDs, and Start menu shortcut paths remain available for other apps. Windows applies the layout after sign-out and sign-in:

```yaml
users:
  current:
    windows:
      personalization:
        taskbar:
          slots:
            exhaustive: true
            apps:
              - app: windows_terminal
              - app: jetbrains_toolbox
              - app: microsoft_edge
```

Start Menu shortcut removal uses relative `.lnk` paths beneath the placement's
`Programs` directory. System placement manages the all-users Start Menu and
runs elevated during apply; user placement manages only the current user's
Start Menu. `oem_pins: absent` removes `LayoutModification.json` from the
Default user template at system placement or from the current profile at user
placement. This prevents OEM pins from being seeded by those files; it doesn't
rewrite an already materialized pinned list. Only explicit absence is supported:

```yaml
system:
  windows:
    personalization:
      start_menu:
        oem_pins: absent
        shortcuts:
          Adobe Promotion.lnk:
            state: absent
```

Each plugin contains `plugin.json`, `schema.json`, and `plugin.ps1`. The plugin protocol uses one versioned JSON request on standard input and an NDJSON stream containing optional events followed by exactly one result on standard output. A plan handler performs its own runtime validation, observation, and planning in a single process; `validate` remains a separate operation for validation-only commands.

See [Writing a Winix plugin (module)](docs/plugin-authoring.md) for the complete
authoring workflow, protocol contract, conventions, and common gotchas.

Observation should prefer one scope-wide list operation followed by an in-memory index or cache. Repeated point queries are reserved for providers that do not expose a safe bulk inventory. Apply handlers must invalidate affected cache entries after mutation before verifying postconditions.

Resource-map keys are semantic identities used during overlay merging. For WinGet, the exact canonical package ID is the key:

```yaml
packages:
  winget:
    Microsoft.VisualStudioCode:
      state: installed
```

Nerd Fonts use the exact release archive name without `.zip` as the key. Omission of `state` means installed; `state: absent` removes a family previously installed by Winix:

```yaml
users:
  current:
    fonts:
      nerd_fonts:
        JetBrainsMono: {}
        FiraCode: {}
        Hack:
          state: absent
```

User WinGet state is queried and removed with `--scope user`. Planning prefers an explicit user-scope installer and falls back to a scope-neutral installer, such as Rustup, only when no machine-scoped installer is applicable. Scope-neutral install and upgrade commands omit the scope filter. These commands still run only in the original unelevated user process. System WinGet operations run elevated with `--scope machine`.

WSL is managed at system scope. Distribution names must exactly match the dynamic
`wsl.exe --list --online` catalog; distro entries do not install Store, WinGet,
AppX, or imported distributions. The distro list is additive, so distributions
omitted from it are left alone. `version: latest` opts into upgrades, and `preview: true`
selects the latest prerelease. A first-time install explicitly enables the
`VirtualMachinePlatform` and `Microsoft-Windows-Subsystem-Linux` Windows features
as a separate restart-requiring pass. After restarting, subsequent plans install
and upgrade WSL before installing the requested distributions. `state: absent` is destructive: it
unregisters every installed distribution, deleting its data, before uninstalling
WSL.

When a system reboot is pending, `plan` and `apply` emit a final
`restart_required` event and exit with Windows code `3010`
(`ERROR_SUCCESS_REBOOT_REQUIRED`). The code is preserved through the elevated
system worker, so PowerShell callers can test `$LASTEXITCODE -eq 3010`. Console
output also explains that configuration is not yet converged and instructs the
user to restart Windows and run Winix again.

```yaml
system:
  windows:
    wsl:
      state: installed
      version: latest
      preview: false
      distros:
        - Ubuntu-24.04
        - Debian
```

The WinGet manifest requires `Microsoft.WinGet.Client` from PSGallery. Requirements are materialized at the same placement as WinGet: `users.current` installs modules with PSResourceGet `CurrentUser`, while `system` uses `AllUsers`. The native catalog metadata backend is the default. Pinget 0.10.0 remains available as an experimental opt-in backend after installing `Devolutions.Pinget.Client`; select it with `WINIX_WINGET_METADATA_BACKEND=pinget`. It falls back to native metadata when unavailable or unable to resolve a historical version. Installation and update remain on Microsoft cmdlets. Scope-qualified CLI observation and uninstall are retained because they provide lossless user/machine registration and explicit removal scope. Planning performs independent scope queries concurrently.

See [ADR 0001](docs/adr/0001-core-architecture-and-initial-modules.md), [ADR 0002](docs/adr/0002-system-and-user-configuration-boundaries.md), [ADR 0003](docs/adr/0003-device-specific-configuration-overlays.md), [ADR 0004](docs/adr/0004-default-configuration-and-plugin-locations.md), [ADR 0005](docs/adr/0005-semantic-resource-map-keys.md), [ADR 0006](docs/adr/0006-structured-operation-event-stream.md), [ADR 0007](docs/adr/0007-system-first-privilege-isolated-apply.md), [ADR 0008](docs/adr/0008-winget-scope-neutral-user-installers.md), [ADR 0009](docs/adr/0009-closed-plan-and-apply-operation-queue.md), [ADR 0011](docs/adr/0011-plugin-required-configuration.md), [ADR 0012](docs/adr/0012-powershell-runtime-bootstrap.md), [ADR 0013](docs/adr/0013-winget-powershell-client.md), [ADR 0014](docs/adr/0014-nerd-fonts-plugin.md), and [ADR 0015](docs/adr/0015-parallel-plugin-planning.md) for the current architectural decisions and deferred work.

## Project information

- Source and issues: [github.com/ibuildthecloud/winix](https://github.com/ibuildthecloud/winix)
- Quality and security roadmap: [initial quality and security review](docs/reviews/2026-07-20-initial-quality-security-review.md)
- Release process and support policy: [releasing Winix](docs/releasing.md)
- Security reports: [security policy](SECURITY.md)
- License: [MIT](LICENSE)
