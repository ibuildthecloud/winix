# ADR 0004: Default configuration and plugin locations

- Status: Accepted
- Date: 2026-07-19
- Decision owners: Winix maintainers

## Context

Routine `winix-cfg` use should not require repeating a configuration path. Windows provides established per-user and machine-wide application-data locations, while the project currently runs directly from a source checkout and has no installer to place built-in plugins in a global location.

Configuration is maintained by the current user even when it contains a system section. Plugins are executable code and system-capable plugins may cross a UAC boundary, so the eventual installed location should be machine-wide and installer-controlled rather than roaming with user settings.

Development needs a convenient way to discover the repository's `plugins` directory without changing production discovery behavior at runtime.

## Decision

### Configuration discovery

Commands that consume configuration accept an optional path. Resolution uses this precedence:

1. An explicit command-line path.
2. The `WINIX_CONFIG` environment variable.
3. `%APPDATA%\Winix\config.yaml`.

The default is based on the Windows Roaming AppData location because configuration belongs to the user and may be synchronized or roam. `winix-cfg` will not search for alternative extensions automatically. JSON, TOML, and alternate YAML filenames remain supported when selected explicitly or through `WINIX_CONFIG`.

Failure messages include the resolved path.

### Plugin discovery

Plugin-directory resolution uses this precedence:

1. An explicit `--plugins-dir` command-line value.
2. The `WINIX_PLUGINS` environment variable.
3. A compile-time default.

The Cargo feature `development-paths` selects `./plugins` as the compile-time default. It is enabled in the repository's default feature set for current development builds.

A build without that feature selects `%ProgramFiles%\Winix\plugins`:

```powershell
cargo build --release --no-default-features
```

The production location is machine-wide because plugins are executable components and may be invoked by the elevated system worker. A future installer and plugin-trust ADR may refine permissions, signing, architecture-specific installation, and bundled-resource layout.

The elevated worker receives the coordinator's already-resolved, canonical plugin directory. It does not perform independent default discovery.

### CLI behavior

The following commands use the default configuration when no path is supplied:

```text
winix-cfg validate
winix-cfg inspect
winix-cfg apply
winix-cfg apply --system
winix-cfg apply --all
```

An explicit path remains a positional argument:

```text
winix-cfg apply .\workstation.yaml --all
```

Schema generation and plugin listing do not consume configuration but use the resolved plugin directory.

## Consequences

### Positive

- Routine apply operations are concise.
- A synchronized configuration can be selected once through `WINIX_CONFIG`.
- Development builds work directly from the repository.
- Production builds do not implicitly trust plugins from the current working directory.
- Plugin and configuration locations remain independently overridable.

### Negative

- Default Cargo builds are development-oriented until packaging is introduced.
- Behavior differs between builds with and without `development-paths`.
- Environment variables add another source of configuration that diagnostics must expose.
- `%ProgramFiles%\Winix\plugins` does not exist until an installer or manual installation creates it.

## Deferred decisions

- Windows Known Folder API use instead of environment-backed path resolution.
- Installer behavior and Program Files architecture selection.
- Plugin signing, permissions, and trusted discovery roots.
- A command that initializes the default user configuration.
- Support for multiple named configuration profiles.
