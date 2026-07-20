# ADR 0017: Windows developer-workstation registry outcomes

- Status: Accepted
- Date: 2026-07-19
- Decision owners: Winix maintainers

## Context

Microsoft's WindowsDeveloperConfig repository defines a developer workstation through a mixture of WinGet packages, scripts, and registry resources. Winix needs to express the same Windows, WSL, and registry-backed outcomes without exposing arbitrary registry writes in user configuration or weakening the protocol-v2 validate/plan/apply boundary.

Several settings are current-user preferences while others are machine policy. The upstream WSL script sets `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss\OOBEComplete` during an elevated WSL installation phase, but Winix keeps interactive-user state separate from system mutation. Some registry contracts, including notification and taskbar settings, are undocumented compatibility boundaries rather than supported public APIs.

## Decision

Winix exposes typed settings through domain-owned plugins and reproduces the pinned WindowsDeveloperConfig registry values:

| Winix property | Placement | Registry contract |
| --- | --- | --- |
| `windows.developer.developer_mode` | system | `AppModelUnlock\AllowDevelopmentWithoutDevLicense` |
| `windows.developer.long_paths` | system | `FileSystem\LongPathsEnabled` |
| `windows.remote_desktop.state` | system | `Terminal Server\fDenyTSConnections` |
| `windows.widgets.state` | system | policy `Dsh\AllowNewsAndInterests` |
| `applications.microsoft_edge.*` | system | Edge `NewTabPageLocation`, `HideFirstRunExperience`, and `ExtensionInstallForcelist` policies |
| `windows.wsl.first_run_oobe` | user | `Lxss\OOBEComplete` |
| `windows.personalization.theme.mode` | user | `AppsUseLightTheme` and `SystemUsesLightTheme` |
| `windows.file_explorer.*` | user | the nine Explorer values adopted from WindowsDeveloperConfig |
| `windows.notifications.*` | user | global toast and PowerToys notification values |
| `windows.search.web_suggestions` | system | original interactive user's policy hive under `HKEY_USERS\<SID>` |
| `windows.search.highlights` | user | current-user Search Settings value |
| `windows.personalization.taskbar.system_tray.show_bluetooth` | user | Bluetooth notification-area value |
| `windows.personalization.taskbar.system_tray.other_icons.*.visibility` | user | Per-application notification-area `IsPromoted` value |
| `windows.multitasking.alt_tab` | user | Explorer `MultiTaskingAltTabFilter` value |

The WSL plugin is dual-placement. Platform state, updates, and distributions remain system-scoped. `first_run_oobe: suppressed` is user-scoped and only suppresses Windows' “Welcome to WSL” experience; it does not bypass a distribution's account creation.

The Search plugin is also dual-placement because `HKCU\Software\Policies\Microsoft\Windows` grants the interactive user read-only access on current Windows builds. `web_suggestions` is declared at system placement and the elevated worker writes the original interactive user's explicit SID beneath `HKEY_USERS`; it never relies on the elevated account's `HKCU`. Search highlights remain an ordinary unelevated user preference.

The taskbar Widgets setting retains its semantic `show_widgets` property. On builds before 26200 it uses the upstream `TaskbarDa` DWORD. On build 26200 and newer it uses the writable string-backed Windows Settings value beneath the `TaskbarDa` subkey because the legacy value is protected.

The Edge plugin can require extensions from Microsoft Edge Add-ons by canonical extension ID. It merges required entries into the numeric `ExtensionInstallForcelist` values without taking ownership of unrelated policy entries. Omitted extensions remain unmanaged. Winix does not edit an extension's private `chrome.storage` data; extension-specific configuration requires a published managed-storage schema.

The multitasking plugin maps `alt_tab: windows_only` to Windows 11's “Don't show tabs” preference. This is an undocumented current-user registry compatibility boundary and reports an Explorer restart requirement.

Windows 11 records the “Other system tray icons” choices beneath dynamically named `NotifyIconSettings` subkeys. Winix does not expose those machine-specific keys. It enumerates the live entries, derives their display names from executable version metadata with the initial tooltip as a fallback, requires each configured name to match exactly one entry case-insensitively, and plans the resolved executable path and entry ID as preconditions. It maps `visibility: shown` to `IsPromoted = 1` and `visibility: hidden` to `IsPromoted = 0`. Apply re-enumerates the entries and rejects a stale, missing, or ambiguous match before changing any icon. Display names can be localized or change with application updates; that portability tradeoff is explicit in exchange for supporting live applications without a hard-coded catalog. This setting controls placement beside the clock versus inside the hidden-icon overflow; it does not install, remove, start, or stop the application.

Remote Desktop deliberately mirrors the upstream `fDenyTSConnections` outcome. It does not claim to install an RDP host on unsupported Windows editions or enable firewall rules. Those would be separate desired outcomes if added later.

Simple fixed registry providers share `Winix.RegistrySettings.psm1`. The adapter binds each operation to a hard-coded semantic definition, preflights the entire queue, rejects altered path/name/type/postcondition data, writes only approved values, and verifies every postcondition. Registry paths and values never come from configuration.

## Consequences

- The roaming configuration can express every active Windows, WSL, and registry-backed outcome in the pinned WindowsDeveloperConfig DSC.
- User settings apply in the original unelevated process; machine settings apply only in the elevated system worker.
- Omitted properties remain unmanaged.
- Explorer-affecting providers report an Explorer restart requirement rather than restarting Explorer during apply.
- Undocumented registry contracts are isolated behind typed semantic properties and can be replaced if Microsoft publishes supported APIs.
- Remote Desktop enablement can remain ineffective on Windows Home or when firewall rules are disabled; the property name documents the host setting rather than promising connectivity.
