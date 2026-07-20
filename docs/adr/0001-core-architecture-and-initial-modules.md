# ADR 0001: Core architecture and initial modules

- Status: Accepted
- Date: 2026-07-18
- Decision owners: Winix maintainers

## Context

Winix is intended to be a larger Windows-focused system. `winix-cfg` will be the part of Winix responsible for declaratively managing Windows configuration.

A user will describe desired state in one configuration document. JSON, YAML, and TOML will be accepted as input formats, but the engine will convert each format into the same JSON-compatible in-memory data model before validation or execution. Support for merging multiple documents is outside the scope of this decision.

Windows configuration APIs and implementation details vary significantly between Windows versions. PowerShell 7 or newer provides straightforward access to Windows commands, the registry, WinGet, and other operating-system integration points. Rust provides a suitable foundation for a reliable command-line program, configuration processing, plugin discovery, validation, and process supervision.

Plugins need to be independently discoverable and self-describing. Each plugin will own a location in a shared configuration tree and define the valid configuration at that location. Users should receive validation errors and IDE completion before configuration is applied.

The initial implementation will manage:

1. Packages installed through WinGet.
2. Desktop personalization settings.
3. Start menu personalization settings.
4. Taskbar personalization settings.

The three personalization areas form one user-facing domain but are separate plugin boundaries because their supported settings and Windows implementations may evolve independently.

## Decision

### Program boundary

The program will be named `winix-cfg`.

The Rust core will be responsible for:

- loading JSON, YAML, or TOML configuration;
- converting input into a JSON-compatible in-memory value;
- discovering plugins and reading their manifests;
- constructing the shared configuration-path tree;
- composing plugin schemas into a root JSON Schema;
- validating configuration before execution;
- routing configuration subtrees to their owning plugins;
- invoking PowerShell 7 plugin entrypoints;
- ordering execution and aggregating structured results and diagnostics;
- coordinating shared effects such as a requested Explorer restart.

PowerShell plugins will be responsible for:

- inspecting the current Windows state;
- validating operating-system-dependent constraints;
- applying Windows-specific changes idempotently;
- translating stable, user-facing configuration concepts into the implementation required by the current Windows version;
- reporting observed state, changes, warnings, failures, and restart requirements as structured data.

Windows-specific implementation details will remain outside the Rust core unless a later decision identifies a compelling reason to move a capability into Rust.

### Configuration model

Configuration is a tree of JSON-compatible objects, arrays, strings, numbers, booleans, and null values. The root document will contain a configuration version and may contain a `$schema` property.

Plugins register ownership of a dotted path. The initial paths are:

| Plugin | Registered configuration path |
| --- | --- |
| WinGet packages | `packages.winget` |
| Desktop personalization | `windows.personalization.desktop` |
| Start menu personalization | `windows.personalization.start_menu` |
| Taskbar personalization | `windows.personalization.taskbar` |

Plugin paths must be unique. A path may act as either a namespace containing child plugin paths or as a plugin-owned configuration value, but not both. Duplicate and overlapping registrations that violate this rule will be rejected during discovery.

Named maps will be preferred over arrays for collections whose members require stable identities. For example, packages will be keyed by a user-chosen local name:

```yaml
version: 1

packages:
  winget:
    powershell:
      id: Microsoft.PowerShell
      state: installed
      version: latest
```

Omitted properties are unmanaged unless a plugin's schema and documentation explicitly state otherwise. Potentially destructive intent must be explicit, such as `state: absent`. User-facing configuration will describe desired outcomes rather than registry keys or imperative commands.

### Plugin packaging and discovery

Each plugin will be stored in its own directory and will initially contain:

```text
plugin-directory/
├── plugin.json
├── schema.json
└── plugin.ps1
```

The manifest will include at least:

- a plugin protocol version;
- a stable plugin name;
- the registered configuration path;
- the PowerShell entrypoint;
- the schema file;
- runtime requirements, including the minimum PowerShell version and whether administrator privileges or external commands are required.

The exact installation locations and third-party plugin distribution mechanism are deferred. The first implementation may discover plugins from a project-owned built-in directory.

### Schema ownership and composition

Each plugin will provide a JSON Schema Draft 2020-12 document describing the value at its registered configuration path. Plugin schemas should include descriptions, enums, examples, and other annotations useful for IDE completion and generated documentation.

The Rust core will compose plugin schemas into a root schema representing the complete configuration tree. The generated root schema will include core properties such as `$schema` and `version` and reference plugin schemas beneath their registered paths.

The CLI will eventually support operations equivalent to:

```text
winix-cfg schema --output winix-cfg.schema.json
winix-cfg validate workstation.yaml
```

JSON documents can select the generated schema with `$schema`. YAML editors may use either the accepted `$schema` property or an editor-specific schema directive. TOML schema integration will depend on editor support, but `winix-cfg` will apply the same validation after parsing.

JSON Schema validates document structure and portable constraints. A plugin must also perform runtime validation for environmental constraints, such as Windows-version support or the availability of WinGet.

Schema `default` annotations will not cause omitted settings to be managed or applied. Defaults, if present, are documentation and editor hints only.

### PowerShell protocol

Rust will invoke plugins using `pwsh` 7 or newer with non-interactive, no-profile execution. Requests will be passed as JSON through standard input, and a plugin will write exactly one protocol response as JSON to standard output. Incidental output must not be mixed with the protocol response; diagnostic information belongs in the structured response or on standard error.

The initial protocol will support these logical operations:

- `validate`: perform plugin-specific and environment-specific validation;
- `get`: observe current state for the requested configuration;
- `set`: converge managed properties on the requested state.

Protocol requests and responses will carry a protocol version. Responses will support structured diagnostics and, where applicable, observed state, whether a change occurred, and restart requirements. The detailed request and response envelopes will be specified as implementation proceeds and may receive a dedicated ADR before the protocol is treated as stable.

The Rust user-facing command may use terms such as `apply`; `set` refers only to the initial plugin protocol operation.

### Initial plugins

#### WinGet packages

The `packages.winget` plugin manages the entire package map in one invocation so it can query installed packages efficiently. Each entry will support a stable WinGet package ID and desired installation state. Optional capabilities will include source, installation scope, an exact version, and the explicit `latest` version policy.

`state: installed` without a version means that any installed version satisfies the declaration. `version: latest` explicitly authorizes upgrades. Removal requires `state: absent`.

#### Desktop personalization

The initial `windows.personalization.desktop` design considered theme, accent, wallpaper image, and individual standard-icon settings. Its implemented scope is intentionally smaller: the current-user desktop-wide icon visibility switch and a solid background color.

The plugin observes and applies the live desktop view through `IFolderView2` and its desktop-only `FWF_NOICONS` flag, refreshes the live Shell view, and persists the corresponding Shell preference with `SHGetSetSettings`. Solid colors use `IDesktopWallpaper.SetBackgroundColor`, `IDesktopWallpaper.Enable(false)`, and per-monitor `GetWallpaper` observation. The plugin does not directly read or write registry values because changing them alone does not update the running Windows 11 desktop.

#### Start menu personalization

The `windows.personalization.start_menu` plugin will manage current-user settings such as recently added apps, most-used apps, recent items, recommendations, and folders displayed by the Start menu where supported.

#### Taskbar personalization

The `windows.personalization.taskbar` plugin will manage current-user settings such as alignment, automatic hiding, search presentation, Task View, widgets, badges, button grouping, Copilot visibility, and selected system-tray preferences where supported.

Personalization plugins may share a PowerShell support module for Windows version detection, registry access, diagnostics, and other common behavior. A plugin will clearly report settings unsupported by the detected Windows version rather than silently ignoring them.

Plugins may report that Explorer or Windows must be restarted, but they will not independently perform shared restarts. The Rust engine will coordinate such effects after all applicable plugins have run.

## Consequences

### Positive

- The Rust core remains portable, testable, and largely independent of changing Windows implementation details.
- PowerShell provides direct and maintainable integration with Windows and WinGet.
- Plugin-owned schemas provide early validation, IDE completion, and a basis for generated reference documentation.
- Path-based ownership creates one coherent configuration tree without requiring the core to understand every feature.
- Separate personalization plugins can evolve and report platform compatibility independently.
- Structured process communication makes plugin execution observable and testable.

### Negative

- Running external PowerShell processes adds startup and serialization overhead.
- The project must carefully prevent ordinary PowerShell output from corrupting protocol responses.
- Composing schemas and detecting path conflicts adds complexity to plugin discovery.
- Personalization implementations may require ongoing maintenance across Windows releases.
- JSON-compatible normalization cannot preserve every format-specific type, such as native TOML date and time values, without an explicit conversion policy.

### Risks

- Some Windows settings have no supported public API and may depend on undocumented registry values.
- WinGet output and behavior may vary by installed version.
- Restarting Explorer can disrupt the user's session if not coordinated and communicated clearly.
- Third-party plugins will eventually introduce trust and execution-security concerns that this ADR does not resolve.

## Deferred decisions

The following require later design work or separate ADRs:

- configuration merging and precedence;
- variables, interpolation, conditions, and secrets;
- dependency declarations and execution ordering between plugins;
- plugin installation, discovery locations, signing, and trust;
- the finalized versioned PowerShell request and response protocol;
- dry-run and planning semantics;
- rollback and persistent state;
- administrator elevation and mixed user/machine execution;
- supported Windows editions and releases;
- behavior for unsupported personalization settings;
- whether and how Explorer or the operating system is automatically restarted.

## Alternatives considered

### Implement Windows functionality directly in Rust

This could avoid PowerShell process overhead and provide stronger compile-time guarantees. It was not selected because PowerShell offers simpler access to the broad and changing set of Windows configuration mechanisms, and the project benefits from keeping platform knowledge in scripts that can evolve independently.

### Use one personalization plugin

A single plugin would reduce the number of manifests and processes. It was not selected because desktop, Start menu, and taskbar configuration have distinct schemas and compatibility concerns. Shared PowerShell helpers retain implementation reuse without coupling their public configuration boundaries.

### Let plugins validate without JSON Schema

Runtime-only validation would be simpler initially. It was not selected because it would prevent complete pre-execution validation, IDE completion, and schema-driven documentation.

### Register imperative actions rather than configuration paths

An action-oriented model could map closely to PowerShell commands. It was not selected because Winix configuration should express desired state, support idempotent application, and leave implementation details to plugins.
