# WindowsDeveloperConfig adoption analysis

- Status: Registry-backed outcomes implemented and added to the personal configuration; remaining developer-environment plugins pending
- Upstream snapshot: `microsoft/WindowsDeveloperConfig` commit [`366712847217e840103ffc8e38c4467fadb24a1d`](https://github.com/microsoft/WindowsDeveloperConfig/commit/366712847217e840103ffc8e38c4467fadb24a1d), committed 2026-07-10
- Upstream entry point: [`windows-dev-config/README.md`](https://github.com/microsoft/WindowsDeveloperConfig/blob/366712847217e840103ffc8e38c4467fadb24a1d/windows-dev-config/README.md)
- Authoritative configuration: [`windows-dev-config/dev-config.winget`](https://github.com/microsoft/WindowsDeveloperConfig/blob/366712847217e840103ffc8e38c4467fadb24a1d/windows-dev-config/dev-config.winget)
- Wrapper: [`windows-dev-config/install.ps1`](https://github.com/microsoft/WindowsDeveloperConfig/blob/366712847217e840103ffc8e38c4467fadb24a1d/windows-dev-config/install.ps1)
- Winix target: `%APPDATA%\Winix\config.yaml`
- Analysis date: 2026-07-19

## Objective and boundary

The goal is to express the effective desired state of `windows-dev-config` in Winix, implement any missing declarative plugins, and then merge the result into the current user's roaming Winix configuration.

This document does not authorize or perform machine mutation. The final migration must follow Winix's protocol-v2 boundary: validate, plan without side effects, review the complete system and user queue, and only then apply with `--all`. Winix should reproduce desired outcomes, not copy DSC orchestration details such as self-elevation, forced reboot, retry loops, or arbitrary script blocks.

The checked-in `dev-config.winget` is authoritative where it differs from the README. It currently contains 51 active resources:

- 15 WinGet packages;
- 24 registry values;
- 3 WSL phase scripts;
- 8 other PowerShell script resources; and
- 1 `OhMyPosh/Shell` resource.

The commented `ElevationCheck` and `HideDesktopIcons` blocks are not active desired state.

## Executive result

Winix has strong generic coverage for packages and useful partial coverage for WSL and personalization, but it cannot yet express the full configuration.

- Package identity/state is available for all 15 packages, subject to canonical ID correction and installer-scope validation. Four packages are already desired in the roaming config at an appropriate existing scope.
- Four of the 24 active registry outcomes already have semantic Winix settings: Sudo, taskbar Widgets visibility, End Task, and Start recommendations. End Task intentionally uses a Windows settings-store adapter rather than the stale direct registry path used upstream.
- WSL installation, named distributions, and the per-user `Lxss\OOBEComplete` outcome are covered. Winix intentionally retains an explicit restart/reconcile cycle.
- The existing Nerd Fonts plugin does not install the same Microsoft Cascadia release or guarantee the required `Cascadia Mono NF` face.
- Dark theme, Explorer behavior, Search policies, notifications, Widgets, Edge policies, Developer Mode, long paths, the Remote Desktop registry outcome, and Windows Terminal defaults are now covered. PowerShell profile integration and .NET templates remain gaps; GitHub Copilot integrations are intentionally excluded from the personal configuration.

No literal registry escape-hatch plugin should be added. The missing behaviors should be represented as closed, typed, domain-owned properties with placement checks, stale-plan protection, and verified postconditions.

## Upstream drift and hazards

The README substantially describes an older revision. These differences must not be silently inherited into Winix:

| Area | README claim | Current DSC at the pinned commit | Consequence |
| --- | --- | --- | --- |
| Elevation | `ElevationCheck` self-relaunches as administrator | The entire resource is commented out | The README's prerequisite/orchestration claim is false. Winix should retain its own system/user privilege isolation. |
| Packages | 14 apps | 15 package resources, including Windows Terminal | Inventory must follow the DSC. |
| Dark theme | Launches `dark.theme` through `RunCommandOnSet` | Writes `AppsUseLightTheme=0` and `SystemUsesLightTheme=0` with `PowerShellScript` | The current outcome is two theme values, not a complete theme-file application. |
| Start recommendations | `Start_Layout=1` | `Start_IrisRecommendations=0` | Use the current semantic outcome; Winix already maps `show_recommendations: false` to `Start_IrisRecommendations`. |
| Oh My Posh | Appends one command to `$PROFILE` | Uses `OhMyPosh/Shell` and also emits console input/output UTF-8 setup | A profile plugin must model a managed block, not append an opaque line. |
| Additional tooling | Not listed | Copilot Terminal fragment, WinUI templates, Copilot marketplace, and WinUI Copilot plugin | These are active and require additional providers. |
| WSL/package ordering | Apps are described as depending on Ubuntu | Package resources do not depend on WSL | WSL is a separate desired-state concern. |
| Recall | Wrapper description says Recall is off | No active Recall resource exists | Recall is out of scope unless separately requested. |
| Start menu name | README table says `Start_Layout` | Actual name is `Start_IrisRecommendations` | README-only transcription would configure the wrong value. |

Additional implementation hazards in the DSC:

- Three package IDs use non-canonical casing. Winix must use `GitHub.cli`, `Microsoft.DotNet.SDK.10`, and `Microsoft.WinAppCli`, not the upstream `GitHub.Cli`, `Microsoft.dotnet.SDK.10`, and `Microsoft.winappcli` spellings.
- `OpenJS.NodeJS.LTS` and `CoreyButler.NVMforWindows` are both installed. This can create competing Node installations and PATH/symlink ownership. Matching upstream exactly requires both, but the personal migration should make an explicit choice before apply.
- Remote Desktop only sets `fDenyTSConnections=0`; it does not enable firewall rules or add RDP host support to unsupported Windows editions. Winix deliberately mirrors that exact outcome and documents the limitation.
- `InstallUbuntu` declares success when *any* distro exists. It does not guarantee Ubuntu. Winix's exact distro list is stricter.
- Terminal JSON mutation removes comments and rewrites the file. `SetCascadiaNfAsDefault` backs up first; `ps7default` does not. Winix should use semantic comparison, preserve unrelated state, and use fragments where Terminal supports them.
- The Copilot Terminal resource tests only whether its fragment file exists, not whether its contents or downloaded icon match. The icon download is not hash-bound.
- The WSL phase force-reboots and uses `RunOnce`. Winix's explicit restart and re-plan behavior is safer and should remain an intentional orchestration difference.

## Coverage matrix

Status meanings:

- **Covered**: expressible now with the intended semantic result.
- **Partial**: a related capability exists, but it does not fully guarantee the upstream result.
- **Gap**: a new plugin or a material plugin extension is required.
- **Orchestration only**: not desired state and should not be copied into a plugin.

### Packages

All package declarations should use `state: installed`, `version: latest`, and `source: winget` to match `useLatest: true`.

| Upstream package | Canonical Winix key | Recommended placement | Status / migration note |
| --- | --- | --- | --- |
| Windows Terminal | `Microsoft.WindowsTerminal` | user | Covered; add. |
| PowerShell 7 | `Microsoft.PowerShell` | user | Covered and already desired; add `version: latest` and `source`. Keep the system-scope `absent` declaration. |
| Git | `Git.Git` | system | Covered and already desired; add `version: latest` and `source`. Keep the user-scope `absent` declaration. |
| GitHub CLI | `GitHub.cli` | user | Covered; add with corrected casing. |
| GitHub Copilot CLI | `GitHub.Copilot` | user | Covered; add. |
| VS Code | `Microsoft.VisualStudioCode` | user | Covered and already desired; add `version: latest` and `source`. Keep the system-scope `absent` declaration. |
| .NET SDK 10 | `Microsoft.DotNet.SDK.10` | unresolved | Partial. Current WinGet metadata exposes only an unscoped candidate. Winix's system provider requires a machine candidate; the user provider may select the neutral installer but cannot prove it will remain unelevated/user-scoped. Resolve via trusted compatibility metadata or verified provider behavior before migration. |
| Python 3.14 | `Python.Python.3.14` | user | Covered; add. |
| uv | `astral-sh.uv` | user | Covered; add. |
| Node.js LTS | `OpenJS.NodeJS.LTS` | user | Covered and already desired; add `version: latest` and `source`. Decide how it coexists with NVM first. |
| NVM for Windows | `CoreyButler.NVMforWindows` | user | Covered; current WinGet manifest is user-applicable, not machine-applicable. Decide how it coexists with standalone Node first. |
| Coreutils for Windows | `Microsoft.Coreutils` | system | Covered; current WinGet manifest is machine-applicable, not user-applicable. |
| Oh My Posh | `JanDeDobbeleer.OhMyPosh` | user | Covered; add. Profile integration remains a separate gap. |
| Windows App Development CLI | `Microsoft.WinAppCli` | user | Covered; add with corrected casing. |
| PowerToys | `Microsoft.PowerToys` | user | Covered; add. AOT notification suppression remains a separate gap. |

Installer applicability was probed against the local WinGet catalog on 2026-07-19. It is moving external state and must be revalidated during the eventual plan.

The helper scripts conditionally enable `winget configure` and install `Microsoft.VCRedist.2015+.x64`. These are prerequisites for the upstream DSC engine, not workstation outcomes. Winix does not use `winget configure`, so they should not be copied into the personal configuration solely for parity. The wrapper also refreshes the current process PATH, retries the entire DSC run up to three times, verifies `git`, and emits a CI sentinel; these are orchestration/CI behaviors.

### Windows, WSL, and registry-backed outcomes

| Upstream outcome | Proposed Winix configuration | Status | Work |
| --- | --- | --- | --- |
| WSL platform installed | `system.windows.wsl.state: installed` | Covered | Already present. |
| Latest/preview WSL | `version: latest`, `preview: true` | Covered, stronger/different | Already present; upstream does not request preview. Decide whether to retain the personal preference or change to stable parity. |
| Ubuntu installed | `system.windows.wsl.distros` | Partial | Current config requests `Ubuntu-26.04`; upstream requests `Ubuntu` but skips if any distro exists. Decide whether to keep the specific distro, add `Ubuntu`, or replace it. Winix only adds requested distros and leaves others installed. |
| Suppress WSL first-run OOBE | `users.current.windows.wsl.first_run_oobe: suppressed` | Covered | Implemented as user-owned state in the dual-placement WSL plugin. |
| Forced reboot and RunOnce resume | none | Orchestration only | Keep Winix's explicit restart-required result and later re-plan/apply. |
| Dark apps/system theme | `users.current.windows.personalization.theme.mode: dark` | Covered | Uses the two current upstream registry values and reports an Explorer restart requirement. |
| Sudo inline | `system.windows.developer.sudo` | Covered | Already present. |
| Developer Mode | `system.windows.developer.developer_mode: enabled` | Covered | Implemented in `windows.developer`. |
| Win32 long paths | `system.windows.developer.long_paths: enabled` | Covered | Implemented in `windows.developer`. |
| Remote Desktop | `system.windows.remote_desktop.state: enabled` | Covered | Mirrors upstream `fDenyTSConnections`; firewall and edition support remain explicitly unmanaged. |
| Show file extensions | `show_file_extensions: true` | Covered | Implemented in user `windows.file_explorer`. |
| Show hidden files | `show_hidden_files: true` | Covered | Implemented in user `windows.file_explorer`. |
| Full path in title bar | `show_full_path_in_title_bar: true` | Covered | Implemented in user `windows.file_explorer`. |
| Open Explorer to This PC | `launch_to: this_pc` | Covered | Implemented in user `windows.file_explorer`. |
| Frequent folders off | `show_frequent_folders: false` | Covered | Implemented in user `windows.file_explorer`. |
| Recent/frequent files off | `show_recent_files: false` | Covered | Implemented in user `windows.file_explorer`. |
| Cloud recommendations off | `show_cloud_files_in_quick_access: false` | Covered | Implemented in user `windows.file_explorer`. |
| Git folders in navigation pane | `show_version_control: true` | Covered | Implemented in user `windows.file_explorer`. |
| Sync-provider tips off | `show_sync_provider_notifications: false` | Covered | Implemented in user `windows.file_explorer`. |
| Do Not Disturb / global toasts off | `users.current.windows.notifications.do_not_disturb: enabled` | Covered | Implements the current upstream value. |
| Widgets taskbar button hidden | `users.current.windows.personalization.taskbar.show_widgets: false` | Covered | Already present. Winix already handles build 26200+'s string-backed setting, unlike the upstream fixed `TaskbarDa` write. |
| Bluetooth tray icon hidden | `system_tray.show_bluetooth: false` | Covered | Implemented in taskbar system-tray support. |
| End Task enabled | `users.current.windows.developer.end_task: enabled` | Covered | Already present. Winix uses the current settings-store location, not upstream's legacy `Advanced\TaskbarEndTask` value. |
| Web suggestions off | `system.windows.search.web_suggestions: false` | Covered | Admin-required per-user policy targets the original user's SID explicitly from system placement. |
| Search highlights off | `users.current.windows.search.highlights: false` | Covered | Implemented in user `windows.search`. |
| Start recommendations off | `users.current.windows.personalization.start_menu.show_recommendations: false` | Covered | Capability exists; add to roaming config. |
| Widget service policy off | `system.windows.widgets.state: disabled` | Covered | System policy is separate from user taskbar visibility. |
| Edge new tab `about:blank` | `system.applications.microsoft_edge.new_tab_page: about:blank` | Covered | Implemented as a typed machine policy. |
| Edge first-run experience off | `system.applications.microsoft_edge.show_first_run: false` | Covered | Implemented as a typed machine policy. |
| PowerToys AOT notifications off | `users.current.windows.notifications.applications.PowerToys.enabled: false` | Covered | Application identity is closed by schema; arbitrary registry paths are not accepted. |
| Hide desktop icons | `users.current.windows.personalization.desktop.icons: disabled` | Not active upstream | Already present as a personal preference; retain unless parity must be exact. |

### Fonts, Terminal, shell, and tool configuration

| Upstream outcome | Status | Work |
| --- | --- | --- |
| Install `CascadiaCodeNF.ttf` and `CascadiaMonoNF.ttf` from Microsoft Cascadia Code `2407.24` | Partial | The existing `fonts.nerd_fonts` provider installs release assets from `ryanoasis/nerd-fonts` and cannot guarantee these files or family names. Add a Microsoft Cascadia provider, or safely generalize font artifacts without exposing executable/download configuration. Bind version, URL, SHA-256, file list, and resulting registrations into the closed plan. |
| Set Terminal default font to `Cascadia Mono NF` | Covered with selected alternative | `applications.windows_terminal` manages the default font semantically; the personal configuration selects the already-managed `JetBrainsMono NFM` face instead of adding another font provider. |
| Set PowerShell 7 as Terminal default profile | Covered | `applications.windows_terminal` resolves the generated PowerShell profile by semantic source at plan time and protects the complete settings file with a stale-plan hash. |
| Add GitHub Copilot Terminal profile and icon | Gap | Support a managed Terminal fragment map. Verify fragment content, use atomic writes, and bind the icon artifact/hash instead of testing file existence only. |
| Initialize Oh My Posh and UTF-8 console input/output in PowerShell 7 | Gap | Add a user PowerShell profile plugin with owned, replaceable blocks/fragments. It must preserve unrelated profile content and avoid dot-sourcing arbitrary existing profile code during apply. |
| Install `Microsoft.WindowsAppSDK.WinUI.CSharp.Templates` with `dotnet new install` | Gap | Add a semantic `dotnet.templates` resource map with canonical identity, version observation where available, idempotence, and dependency on .NET SDK. |
| Add Copilot marketplace `microsoft/win-dev-skills` | Gap | Add a user `github.copilot_cli` provider with semantic marketplace identities and authenticated-state diagnostics. |
| Install `winui@win-dev-skills` Copilot plugin | Gap | Same Copilot provider, with marketplace/plugin dependency ordering and exact postcondition checks. |

## Recommended implementation backlog

The sequence below minimizes ambiguous ownership and unlocks a reviewable personal plan.

### P0: resolve migration decisions

1. Choose standalone Node LTS, NVM, or deliberate coexistence. Do not blindly inherit both.
2. Choose WSL parity: retain `Ubuntu-26.04`, add generic `Ubuntu`, or replace the configured distro name.
3. Decide whether the personal `preview: true` WSL preference remains; upstream requests no preview channel.
4. Decide whether optional-by-description packages Oh My Posh and PowerToys are included. They are active resources upstream, so strict parity includes them.
5. Remote Desktop follows the upstream registry-only behavior. Firewall and edition support remain separately unmanaged.

### P1: core Windows outcome plugins (completed)

1. Extended `windows.developer` with system-only `developer_mode` and `long_paths`.
2. Added `windows.file_explorer` for the nine Explorer outcomes.
3. Added `windows.search` for web suggestions and highlights.
4. Added `windows.notifications` for global notifications and the schema-closed PowerToys notification identity.
5. Extended taskbar `system_tray` with Bluetooth icon visibility.
6. Added `windows.personalization.theme`.
7. Added system-owned `windows.widgets` and `applications.microsoft_edge` plugins.
8. Added registry-compatible `windows.remote_desktop`; firewall state remains explicitly outside the upstream-compatible contract.

Each registry-backed property needs Windows-build validation, converged/changed tests, whole-queue stale preflight, postcondition verification, and accurate `restart_required.explorer/system` reporting. Regression fixtures must include omitted properties and deliberately reordered structured preconditions.

### P2: developer environment plugins

1. Implement a Cascadia font provider that guarantees the `Cascadia Mono NF` face.
2. Add `windows.terminal` for default font/profile and managed fragments.
3. Add a PowerShell profile managed-block provider for Oh My Posh and encoding setup.
4. Add `dotnet.templates`.
5. Add `github.copilot_cli` marketplaces/plugins.
6. Resolve trusted system handling for the unscoped .NET SDK installer, without weakening the general user/system placement contract.

### P3: personal configuration migration

After P0 decisions and required providers land:

1. Back up `%APPDATA%\Winix\config.yaml`.
2. Merge the canonical package declarations without removing existing personal absence rules or unrelated desired state.
3. Add `show_recommendations: false` immediately; Sudo, End Task, and taskbar Widgets are already configured.
4. Add new plugin properties only after their schemas and runtime validation exist.
5. Generate the composed schema and validate the default config.
6. Run `cargo run -- plan --all --output trace` using the default config. Review system changes first, especially Remote Desktop, Developer Mode, long paths, widgets policy, Edge policy, Coreutils, and .NET SDK.
7. Apply only after the complete plan is accepted. Expect WSL to require a restart and a subsequent plan/apply cycle; Winix must not force-reboot or install unplanned follow-up work.
8. Re-run plan and require an empty queue to demonstrate convergence.

## Target personal-config shape

The registry-backed portion of this design is now valid and present in the roaming configuration. Remaining `TODO plugin` comments belong to the separate developer-environment backlog. Existing unrelated entries remain in place.

```yaml
system:
  packages:
    winget:
      Git.Git: { state: installed, version: latest, source: winget }
      Microsoft.Coreutils: { state: installed, version: latest, source: winget }
      Microsoft.DotNet.SDK.10: { state: installed, version: latest, source: winget } # blocked: scope handling
  windows:
    developer:
      sudo: { state: enabled, mode: inline }
      developer_mode: enabled
      long_paths: enabled
    remote_desktop:
      state: enabled
    search:
      web_suggestions: false
    widgets:
      state: disabled
    wsl:
      state: installed
      version: latest
      preview: true # personal preference; P0 decision
      distros: [Ubuntu-26.04] # P0 decision
  applications:
    microsoft_edge:
      new_tab_page: about:blank
      show_first_run: false

users:
  current:
    packages:
      winget:
        Microsoft.WindowsTerminal: { state: installed, version: latest, source: winget }
        Microsoft.PowerShell: { state: installed, version: latest, source: winget }
        GitHub.cli: { state: installed, version: latest, source: winget }
        GitHub.Copilot: { state: installed, version: latest, source: winget }
        Microsoft.VisualStudioCode: { state: installed, version: latest, source: winget }
        Python.Python.3.14: { state: installed, version: latest, source: winget }
        astral-sh.uv: { state: installed, version: latest, source: winget }
        OpenJS.NodeJS.LTS: { state: installed, version: latest, source: winget }
        CoreyButler.NVMforWindows: { state: installed, version: latest, source: winget } # P0 decision
        JanDeDobbeleer.OhMyPosh: { state: installed, version: latest, source: winget }
        Microsoft.WinAppCli: { state: installed, version: latest, source: winget }
        Microsoft.PowerToys: { state: installed, version: latest, source: winget }
    windows:
      developer:
        end_task: enabled
      file_explorer:
        show_file_extensions: true
        show_hidden_files: true
        show_full_path_in_title_bar: true
        launch_to: this_pc
        show_frequent_folders: false
        show_recent_files: false
        show_cloud_files_in_quick_access: false
        show_version_control: true
        show_sync_provider_notifications: false
      notifications:
        do_not_disturb: enabled
        applications:
          PowerToys:
            enabled: false
      search:
        highlights: false
      personalization:
        theme:
          mode: dark
        start_menu:
          show_recommendations: false
        taskbar:
          show_widgets: false
          system_tray:
            show_bluetooth: false
      wsl:
        first_run_oobe: suppressed
      terminal: # TODO plugin
        default_profile: powershell
        defaults:
          font_face: Cascadia Mono NF
        profiles:
          github_copilot: { state: present }
    fonts:
      cascadia_code: # TODO plugin
        version: 2407.24
        variants: [code_nf, mono_nf]
    powershell:
      profile: # TODO plugin
        oh_my_posh: enabled
        utf8_console: enabled
    dotnet:
      templates: # TODO plugin
        Microsoft.WindowsAppSDK.WinUI.CSharp.Templates: { state: installed }
    github:
      copilot_cli: # TODO plugin
        marketplaces:
          microsoft/win-dev-skills: { state: present }
        plugins:
          winui@win-dev-skills: { state: installed }
```

## Completion criteria

Adoption is complete when:

- every active upstream desired outcome is either represented by a semantic Winix property or explicitly documented as an intentional orchestration/safety divergence;
- the P0 scope/tool choices are resolved;
- every new plugin passes schema composition, runtime validation, converged and change-required plans, stale-plan rejection, postcondition verification, idempotence, placement-boundary, and stdout-cleanliness tests;
- the roaming configuration validates without TODO properties;
- a reviewed `--all` trace contains only expected operations;
- apply is performed on the intended Windows machine after backup; and
- the post-apply plan is empty, except for a documented WSL restart/reconcile phase if one remains.
