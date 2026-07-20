# WinUtil feature adoption analysis

Date: 2026-07-19

WinUtil source reviewed: `ChrisTitusTech/winutil` `main` at commit `5c104d02e26d803ee8abbba727ba36a14a12acb2` (2026-07-16)

Scope: non-application-management features that may be useful in Winix

## Executive conclusion

WinUtil is a valuable recipe catalog, but it should not become Winix's execution model.
Its best ideas are the individual Windows policies, registry-backed preferences,
optional-feature operations, and a few well-scoped system configurations. Winix should
reimplement those as typed, observable, idempotent resources. It should not import
WinUtil's checkbox orchestration, embedded script strings, hard-coded "undo" values,
application catalog, or broad presets.

Recommended outcome:

1. Build reusable, type-aware registry, service, native-command, and optional-feature
   helpers in the Winix plugin SDK.
2. Extend the existing personalization plugins and add focused plugins for Windows
   privacy/experience, optional features, networking/DNS, power, and update policy.
3. Treat repairs, cleanup, restore-point creation, and network/update resets as explicit
   one-shot actions in a future action subsystem, not desired configuration.
4. Exclude specific application management as requested. This includes WinUtil's app
   catalog, AppX catalog/preset, browser policies, Edge/OneDrive/Widgets removal,
   PowerShell profile, O&O ShutUp10++, Adobe host blocking, and Razer-specific logic.
5. Reject dangerous "debloat" defaults: disabling Windows Update, BitLocker, IPv6, or
   broad sets of services; weakening RDP warnings; store database ACL tricks; and the
   aggressive Windows Update reset.

The suggested first implementation tranche is about 20 semantic settings across five
plugins. That captures most of WinUtil's broadly useful value without inheriting its
application-management focus or its safety weaknesses.

## What was reviewed

The analysis covered:

- All 67 entries and 123 registry actions in
  [`config/tweaks.json`](../../.research/winutil/config/tweaks.json).
- All 33 entries in [`config/feature.json`](../../.research/winutil/config/feature.json),
  including six optional-feature bundles containing 13 feature names, six repair/fix
  buttons, 14 legacy panel launchers, OpenSSH, AutoLogon, and the PowerShell profile.
- The four presets in [`config/preset.json`](../../.research/winutil/config/preset.json).
- Registry, service, status, DNS, optional-feature, update, repair, network-reset,
  OpenSSH, and offline-ISO implementations under
  [`functions`](../../.research/winutil/functions).
- WinUtil's Pester coverage, especially
  [`tweaks.Tests.ps1`](../../.research/winutil/pester/tweaks.Tests.ps1),
  [`configs.Tests.ps1`](../../.research/winutil/pester/configs.Tests.ps1), and
  [`toggle-status.Tests.ps1`](../../.research/winutil/pester/toggle-status.Tests.ps1).
- Winix's Rust host, plugin protocol, shared PowerShell SDK, current package plugins,
  and desktop/start-menu/taskbar personalization plugins.

No WinUtil tweak was executed. This is a static code and architecture review. Windows
build-specific settings still require test VMs before adoption.

## Why WinUtil's recipes fit Winix—but its engine does not

WinUtil represents a tweak as display metadata plus optional registry, service, script,
and AppX actions. [`Invoke-WinUtilTweaks.ps1`](../../.research/winutil/functions/private/Invoke-WinUtilTweaks.ps1)
dispatches those actions directly. This is effective for a GUI utility, but it has four
important limitations for a configuration engine:

1. **There is no complete plan.** A selection goes directly to mutations. Registry and
   service status can be inspected, but arbitrary scripts are not modeled as resources
   with before/after state.
2. **"Undo" is a stock assumption, not rollback.** `OriginalValue` and `OriginalType`
   are constants in JSON. They are not the values that existed before WinUtil changed
   the machine. Undo can therefore overwrite an administrator policy or a user's prior
   choice.
3. **Failures can be hidden.**
   [`Set-WinUtilRegistry.ps1`](../../.research/winutil/functions/private/Set-WinUtilRegistry.ps1)
   and [`Set-WinUtilService.ps1`](../../.research/winutil/functions/private/Set-WinUtilService.ps1)
   catch and log many errors without failing the enclosing tweak. The workflow can reach
   its completion message without proving the desired state.
4. **Bundles mix separate policy decisions.** "Telemetry - Disable," for example,
   combines 12 registry values, two services, Defender sample submission, a machine
   environment variable, and a feedback value. Users cannot independently choose or
   reason about those effects.

Winix already has the right control plane: scope isolation, schema composition, a
side-effect-free planning phase, closed operation queues, stale-plan checks, and
structured events. The current taskbar and Start plugins demonstrate the desired
pattern: observe a named resource, plan a typed operation, verify that the plan is not
stale, apply, and report restart impact. See
[`README.md`](../../README.md),
[`taskbar/plugin.ps1`](../../plugins/windows/personalization/taskbar/plugin.ps1), and
[`start-menu/plugin.ps1`](../../plugins/windows/personalization/start-menu/plugin.ps1).

## Design rules for adoption

### Use semantic configuration, not tweak IDs

Prefer:

```yaml
system:
  windows:
    experience:
      consumer_features: disabled
      activity_history: disabled
    networking:
      delivery_optimization:
        mode: http_only
    features:
      Microsoft-Windows-Subsystem-Linux: enabled

users:
  current:
    windows:
      privacy:
        advertising_id: disabled
        tailored_experiences: disabled
      explorer:
        show_file_extensions: true
        show_hidden_files: true
```

Avoid exposing names such as `WPFTweaksTelemetry` or raw registry paths in normal user
configuration. The schema should describe the Windows behavior; the plugin owns its
current implementation.

### Make policy removal expressible

Many WinUtil undo values use `<RemoveEntry>`, which is often correct for returning a
policy to Windows or organizational control. A Boolean is insufficient because it
cannot distinguish "explicitly enable" from "not configured." Policy-shaped settings
should generally use:

```yaml
consumer_features: disabled # writes the supported policy
consumer_features: enabled  # writes the inverse policy when meaningful
consumer_features: not_configured # removes Winix's policy value
```

Omitting the property means Winix does not manage it. `not_configured` is useful when a
configuration explicitly needs to remove a previously managed policy.

### Split mixed-scope bundles

WinUtil's telemetry recipe contains HKCU and HKLM changes in one elevated workflow.
Winix should put machine policy under `system` and user preferences under
`users.current`. That preserves Winix's privilege boundary and avoids applying HKCU
changes to the elevated administrator identity.

### Keep durable state separate from actions

The following are actions, not configuration: create a restore point, empty temporary
directories, run SFC/DISM/CHKDSK, reset Winsock, reset Windows Update, build an ISO, and
launch Control Panel. Re-running them has work or side effects even when the machine is
already in the intended state. They need a future command/action protocol with preview,
confirmation, progress, cancellation, and explicit destructive-risk metadata.

### Require authoritative postconditions

Every adopted resource should re-observe after mutation. A command returning exit code
zero is not enough for optional features, services, DNS, update policies, scheduled
tasks, or boot configuration. This matches the stronger postcondition behavior already
present in Winix's package plugins.

### Model applicability

Registry recipes vary by Windows build and edition. Each plugin should emit a diagnostic
when a setting is unsupported, distinguish "not applicable" from "already desired," and
avoid creating obsolete keys blindly. At minimum, planning should capture OS build,
edition, and relevant feature/service existence in the operation's `before` data.

## Recommended plugin architecture

| Plugin path | Placement | Responsibilities |
| --- | --- | --- |
| `windows.personalization.taskbar` | user | Extend the existing plugin with battery percentage and End Task. Alignment, search, Task View, and Widgets visibility already exist. |
| `windows.personalization.start_menu` | user | Keep the existing recommendations setting; add web/Bing search only after confirming the current supported policy. |
| `windows.personalization.theme` | user | App/system light mode and always-visible scrollbars. |
| `windows.explorer` | user | File extensions, hidden files, launch target, Home/Gallery visibility, classic context menu, folder-type discovery. |
| `windows.experience` | system and user | Consumer features, activity history, advertising ID, tailored experiences, input personalization, feedback prompts, location consent. Keep each leaf independent. |
| `windows.system_behavior` | system and user | Long paths, verbose logon, detailed crash screen, lock-screen behavior, UTC hardware clock. Do not turn this into a raw registry surface. |
| `windows.power` | system | Hibernation mode and carefully scoped sleep settings with laptop/hardware diagnostics. |
| `windows.networking.dns` | system | Per-interface or selector-based DNS state, DHCP reset, IPv4 and IPv6 server lists. |
| `windows.networking.delivery_optimization` | system | Semantic download mode and, later, bandwidth/cache settings. |
| `windows.features.optional` | system | Resource map of exact optional-feature names with `enabled`/`disabled`; observe with `Get-WindowsOptionalFeature`. |
| `windows.update.policy` | system | Driver inclusion, feature/quality deferral, restart behavior. Do not manage service disabling here. |
| `windows.services` | system | Optional explicit service resource map. No hidden "debloat" list or default service preset. |
| `windows.storage` | system and user | Reserved storage and Storage Sense configuration, after build-specific validation. |
| `windows.remote_access.openssh` | system | OpenSSH capability, service startup, firewall rule, and explicit authentication choices. High-risk opt-in. |

Do not add a generic public `registry.values` plugin merely to port WinUtil faster. It
would freeze registry implementation details into user configuration, bypass semantic
validation, and make compatibility migrations the user's problem.

## Shared SDK work needed first

[`Winix.PluginSdk.psm1`](../../plugins/shared/Winix.PluginSdk.psm1) currently has useful
property helpers, but broad system configuration needs stronger primitives:

- `Get-WinixRegistryValueState`: return presence, value, and registry type rather than
  collapsing a missing value to `$null`.
- `Set-WinixRegistryValue` and `Remove-WinixRegistryValue`: type-aware equality,
  idempotent removal, and no swallowed errors.
- Service observation and mutation helpers that preserve `AutomaticDelayedStart`,
  distinguish missing services, and verify the postcondition.
- A native-process helper that captures executable, arguments, exit code, stdout/stderr,
  accepted exit codes, timeout, and restart signals without invoking a shell string.
- Optional-feature helpers that understand `Enabled`, `Disabled`,
  `DisabledWithPayloadRemoved`, parent dependencies, and restart-required results.
- A standard typed equality helper for stale-plan checks. Stringifying everything can
  conflate registry types and null/absence.
- Common diagnostic codes for unsupported OS build/edition, missing feature/service,
  policy conflict, restart required, destructive action, and external management.

These should remain implementation helpers. Planned operations must still contain all
data required to validate and execute the closed queue; apply must not reinterpret the
current configuration.

## Adoption matrix: WinUtil tweaks

Ratings:

- **P1**: high-value, broadly applicable, and suitable for early implementation.
- **P2**: useful but needs compatibility, UX, or safety design first.
- **Action**: useful only as an explicit one-shot operation, not desired state.
- **Exclude**: application-specific, outside the requested scope.
- **Reject**: should not be adopted as a normal Winix feature.

### Essential tweaks

| WinUtil feature | Decision | Winix treatment and rationale |
| --- | --- | --- |
| Activity History - Disable | P1 | `windows.experience.activity_history`; separate feed, publish, and upload only if users need that granularity. Use supported policy state and `not_configured` rollback. |
| Hibernation - Disable | P1 | `windows.power.hibernation`; offer `enabled`, `disabled`, and possibly `fast_startup_only`. Warn that disabling hibernation also removes hybrid sleep and Fast Startup. |
| Widgets - Remove | Exclude | This is AppX removal, not taskbar visibility. Winix already supports taskbar Widgets visibility; package removal remains in the explicit AppX plugin. |
| Store recommended search results - Disable | Reject | WinUtil denies `Everyone:F` on the Store database. ACL mutation is brittle, can break Store behavior, and its "undo" grants broad full control rather than restoring the original ACL. |
| Location Tracking - Disable | P2 | Split machine consent, sensor, maps auto-update, and `lfsvc` startup. Do not silently disable all four behind one Boolean. |
| Services - Set to Manual | P2 infrastructure; reject preset | An explicit `windows.services` plugin is useful. Do not copy the CscService/DiagTrack/MapsBroker/StorSvc/SharedAccess bundle or RAM-based `SvcHostSplitThresholdInKB` as a default. Service needs vary by features such as offline files, ICS/hotspot, maps, diagnostics, and storage. |
| Consumer Features - Disable | P1 | Strong candidate as a supported machine policy. Emit an applicability warning on editions where the policy is not honored. |
| Telemetry - Disable | P1 components; reject bundle | Implement advertising ID, tailored experiences, activity publication, feedback prompts, input personalization, diagnostic-data level, Defender samples, services, and PowerShell telemetry as independent resources. Never label the aggregate as fully disabling telemetry. |
| Delivery Optimization - Disable | P1, renamed | Model `http_only`, `lan_peers`, `group_peers`, `internet_peers`, and `offline_http`. WinUtil value `0` means HTTP with no peering, not disabling Delivery Optimization. |
| BitLocker - Disable | Reject | `Disable-BitLocker` decrypts the volume and removes protectors. It is security management, not debloat. If Winix later manages BitLocker, desired protection should default secure and require recovery-key safeguards. |
| File Explorer automatic folder discovery - Disable | P2 | Potentially useful, but first apply deletes the user's Explorer Bags/BagMRU view history. Treat that deletion as a separately confirmed migration action; durable `FolderType=NotSpecified` can be planned afterward. |
| Restore Point - Create | Action | Useful preflight action for risky batches, but not an always-converged setting. Observe whether System Restore is available and report restore-point throttling/failure. |
| Disk Cleanup - Run | Action, split | `cleanmgr /VERYLOWDISK` may be a cleanup action. Do not combine it by default with DISM `/ResetBase`, which makes installed component updates non-uninstallable. |
| Temporary Files - Remove | Reject as written | Broad recursive deletion of user and Windows temp globs has race, lock, and scope problems. A future cleanup action should enumerate candidates, respect age/exclusions, preview reclaimed bytes, and report per-file failures. |
| End Task with taskbar right click | P1 | Add `end_task` to the existing taskbar plugin, build-gated and Explorer-restart-aware. |
| Previous Start layout | Reject | WinUtil writes an undocumented feature-management override under `ControlSet001`. Do not ship undocumented build-specific feature flags as durable configuration. |
| Windows Platform Binary Table execution - Disable | P2 | Interesting security-hardening option, but validate the registry behavior on supported Windows builds and document OEM firmware-update implications before exposing it. |
| Prevent Device Companion Apps | P2 | Treat as a device-metadata policy, not generic debloat. It can affect automatic device metadata/software experiences. |

### Personalization and shell preferences

| WinUtil feature | Decision | Winix treatment and rationale |
| --- | --- | --- |
| Detailed BSoD | P1 | Two machine crash-control values; semantic Boolean with reboot applicability documentation. |
| Dark Theme | P1 | Separate app and system theme if desired; refresh Explorer/theme without embedding UI-specific callbacks. |
| File extensions | P1 | Add to `windows.explorer`; direct, reversible HKCU preference. |
| Hidden files | P1 | Add to `windows.explorer`; direct, reversible HKCU preference. Consider a separate protected-system-files setting later. |
| Long paths | P1 | Machine resource with OS/app compatibility note. |
| Lock screen disable | P2 | Machine policy with edition applicability and security/privacy implications. |
| Logon blur | P1 | Machine personalization policy. Name the semantic behavior (`acrylic_background`) rather than the inverse registry value. |
| Verbose logon | P1 | Machine system behavior; useful for troubleshooting and low risk. |
| New Outlook | Exclude | Application-specific Office/Outlook policy. |
| Mouse acceleration | P1 | User input preference; preserve all three values as one atomic semantic resource. |
| Multiplane Overlay | P2 | Hardware/driver workaround, not a general preference. Require an advanced flag and document that behavior is GPU/driver-specific. |
| Num Lock on startup | P2 | It touches both current user and `.Default`; scope and first-logon semantics need careful design. |
| S0 network connectivity | P2 | Hardware-specific power setting. Detect Modern Standby capability before planning. |
| Force S3 sleep | Reject as general feature | `PlatformAoAcOverride` is a hardware workaround with firmware/driver consequences. Do not present it as universally supported. |
| Always-visible scrollbars | P1 | User accessibility/personalization setting. |
| Settings Home page | P2 | Validate current build behavior and use semantic `visible`/`hidden`/`not_configured`; WinUtil's toggle values are not self-explanatory. |
| Start Bing search | P1 after policy validation | The WinUtil toggle is phrased positively and writes `1`; debloat profiles commonly want the inverse. Make the Winix schema unambiguous (`web_search: enabled/disabled`). |
| Start recommendations | Already present | Winix already exposes `show_recommendations`; validate current implementation against supported policy/build behavior rather than adding WinUtil's three machine values. |
| Sticky Keys | P2 | Accessibility setting; do not hide behind a debloat preset. Expose explicit behavior and avoid overwriting unrelated flag bits. |
| Battery percentage | P1 | Add to the taskbar/system-tray schema with Windows-build applicability. |
| Taskbar alignment | Already present | Existing Winix taskbar plugin is preferable. |
| Taskbar search | Already present | Existing Winix schema is more expressive (`hidden`, `icon`, `box`). |
| Task View | Already present | Existing Winix taskbar Boolean. |
| Window snapping | P1 | User desktop behavior; simple semantic Boolean. |
| Game Mode | P2 | User gaming preference, not debloat. Keep optional and independent. |

### Advanced tweaks

| WinUtil feature | Decision | Winix treatment and rationale |
| --- | --- | --- |
| Adobe URL block list | Exclude/Reject | Application-specific; downloads a mutable third-party hosts list and appends without ownership/deduplication. |
| Background Apps - Disable | P2 | Broad user policy can break notifications/background work. Prefer per-capability or clearly labeled global control with applicability tests. |
| Brave debloat | Exclude | Application-specific browser policy. |
| Hardware clock UTC | P2 | Useful for dual-boot systems; machine time setting with explicit warning. |
| Reserved Storage - Disable | P2 | Model reserved-storage state and observe with DISM. Warn about update reliability and OS eligibility. |
| DNS provider | P1 | Good candidate, but configure selected adapters declaratively and compare ordered IPv4/IPv6 server sets. Support DHCP explicitly; do not mutate only currently-up adapters without remembering selector intent. |
| Explorer Home/Gallery | P1/P2 | `LaunchTo` is P1; namespace CLSID pinning is build-specific P2. Separate these settings. |
| Fullscreen Optimizations - Disable | P2 | Per-user gaming compatibility workaround, not a default performance tweak. |
| IPv6 - Disable | Reject | Microsoft documents IPv6 as a mandatory Windows component and warns that components may fail. WinUtil also changes both a global bitmask and every adapter binding, broadening blast radius. |
| Prefer IPv4 over IPv6 | P2 | This is the safer advanced network preference. Use the documented bitmask, preserve unrelated bits, require reboot reporting, and do not call it IPv6 disablement. |
| Edge debloat | Exclude | Application-specific browser policy. |
| Edge removal | Exclude/Reject | Application removal and forced uninstall. |
| OneDrive removal | Exclude/Reject | Application removal plus destructive file/service operations. |
| O&O ShutUp10++ | Exclude | Downloads/runs a separate third-party system-tweaking application. |
| Razer auto-install block | Exclude | Vendor-specific driver/software workaround with ACL manipulation. |
| Unsigned RDP warnings - Disable | Reject | Weakens a security warning; not debloat. |
| Classic right-click menu | P1/P2 | Useful Explorer preference. Build-gate it and model Explorer restart. |
| Storage Sense - Disable | P2 | Prefer configuring Storage Sense behavior over blanket disablement. Keep it independent from destructive cleanup actions. |
| Notifications and calendar - Disable | P2 | Broad user-experience change. Expose notification center and toast notifications separately. |
| Teredo - Disable | P2 | Advanced networking policy only. It can affect Xbox, NAT traversal, and enterprise scenarios; do not include in a default profile. |
| Best-performance visual effects | P2 | Break into individual user preferences or a clearly expanded profile. Do not combine taskbar search/Task View with animation and rendering choices. Preserve the binary `UserPreferencesMask` carefully. |
| Windows AI - Disable and Remove | P2 policies; exclude removals | Separate supported AI/Recall/Copilot/Notepad policies and optional-feature state. Exclude AppX/WinGet removals and the AppxAllUserStore `EndOfLife` hack. |
| Ultimate Performance enable/disable | P2 | Explicit power-plan resource with laptop warning and observation by plan GUID. No default preset. |

## Adoption matrix: features and fixes

### Optional Windows features

Build one generic semantic plugin and let users name exact Windows feature identities:

| WinUtil bundle | Decision | Notes |
| --- | --- | --- |
| .NET Framework 3/4 | P1 | Manage exact component states. `.NET 4` is normally part of the OS; report non-applicability rather than forcing. NetFx3 may need installation media/source in managed environments. |
| Hyper-V | P1 | Check edition, virtualization capability, feature dependencies, and reboot. |
| Windows Sandbox | P1 | Check edition and virtualization requirements; reboot-aware. |
| WSL + VirtualMachinePlatform | P1 | Feature state is useful, but distro/application installation remains separate. Do not treat feature enablement alone as complete WSL provisioning. |
| NFS client | P2 | Feature state is P1-capable; WinUtil's anonymous UID/GID and `fileaccess=755` configuration must be separate explicit NFS client settings. |
| Legacy Media/DirectPlay | P2 | Supported resource mechanics, but these legacy components should be opt-in for a known workload rather than a convenience preset. |

Microsoft's current guidance identifies `Get-WindowsOptionalFeature`,
`Enable-WindowsOptionalFeature`, and `Disable-WindowsOptionalFeature` as the supported
management surface. Winix should capture the cmdlet's restart result and verify final
state.

### Durable system features

| WinUtil feature | Decision | Notes |
| --- | --- | --- |
| Daily registry backup task | P2 | Split the registry backup policy from scheduled-task definition. Use a real executable/action rather than `schtasks` launching another task, observe the existing task, and avoid overwriting a non-Winix task of the same name. |
| Legacy F8 recovery menu | P2 | Model BCD boot-menu policy with exact observation and administrator scope. It affects boot behavior and may interact with Secure Boot/device recovery. |
| OpenSSH Server | P2/high risk | Useful focused plugin. WinUtil enables services, opens port 22, and modifies authentication config; Winix must expose each security choice, validate firewall scope, avoid overwriting `sshd_config`, and confirm the server is listening. |
| NTP pool | P2 | Make peers and flags configurable; do not assume `pool.ntp.org` is better for every machine/domain. Detect domain-managed time before applying. |
| AutoLogon | Reject by default | Credential-bearing and security-sensitive. Never place plaintext credentials in Winix configuration or operation events. A future secrets-aware subsystem would be prerequisite. |

### One-shot fixes and launchers

| WinUtil feature | Decision | Notes |
| --- | --- | --- |
| System corruption scan | Action | CHKDSK, SFC, then DISM are useful diagnostics/repairs, but report each exit code and result separately. Consider DISM before SFC depending on the intended repair strategy. |
| Network reset | Action | Winsock/IP reset is disruptive and reboot-requiring. Preview affected state and require confirmation. |
| Windows Update reset | Reject as written; possible scoped actions later | The aggressive path deletes broad HKCU/HKLM policy trees, resets security policy, deletes Group Policy directories, resets networking, removes BITS jobs, and re-registers many DLLs. This exceeds a Windows Update repair boundary. A future repair should offer narrowly diagnosed stages. |
| WinGet reinstall | Exclude | Application/package-manager maintenance; outside this report. |
| Legacy Control Panel launchers | Do not put in config engine | Useful GUI shortcuts perhaps, but they have no desired state and no role in plan/apply. A future Winix UI can link them without plugins. |
| PowerShell profile install/remove | Exclude | Application/user-environment-specific content management. |

## Update-policy recommendation

WinUtil's "recommended" update mode is directionally useful but too opinionated as one
button. It restores update services/tasks, excludes drivers, defers feature updates 365
days, defers quality updates four days, and suppresses automatic reboot while a user is
logged in. Winix should expose the decisions independently:

```yaml
system:
  windows:
    update:
      enabled: true
      include_drivers: false
      feature_deferral_days: 30
      quality_deferral_days: 4
      restart_while_user_logged_on: disabled
```

The actual schema should use ranges and build/edition applicability from current Windows
Update policy documentation. `enabled: false` should not initially be offered: disabling
BITS, Windows Update, Update Orchestrator, and scheduled tasks suppresses security
updates and creates a repair burden. `not_configured` should remove only values owned by
the Winix resource, not unrelated organizational policy.

## Privacy and "debloat" recommendation

Avoid a single `telemetry: disabled` promise. Some diagnostic data levels depend on
edition and organizational configuration, and several WinUtil values control
personalization rather than telemetry transport. A clear schema would resemble:

```yaml
system:
  windows:
    privacy:
      diagnostic_data: required
      activity_history:
        feed: disabled
        publish: disabled
        upload: disabled

users:
  current:
    windows:
      privacy:
        advertising_id: disabled
        tailored_experiences: disabled
        online_speech_recognition: disabled
        inking_and_typing_personalization: disabled
        feedback_frequency: never
```

Important differences from WinUtil:

- Do not automatically disable Windows Error Reporting; it is valuable for diagnostics.
- Do not couple Defender sample submission to Windows privacy settings. It is a security
  tradeoff and belongs under a Defender/security resource if implemented.
- Do not couple PowerShell telemetry to Windows OS telemetry. A machine environment
  variable is a separate runtime policy.
- Do not claim `AllowTelemetry=0` guarantees no diagnostic data on every Windows edition.
- Preserve policy removal as a first-class desired state.

## DNS recommendation

WinUtil ships eight provider presets and applies to adapters that are currently `Up`.
Winix should avoid embedding a provider catalog as the core model. The core resource
should accept server addresses and adapter selectors; example configurations may define
well-known providers.

Required planning behavior:

1. Resolve selector to stable adapter identities and show them in the plan.
2. Observe DHCP/static source and ordered IPv4/IPv6 DNS addresses for each adapter.
3. Plan one operation per adapter with complete before/after state.
4. On apply, reject stale adapter/state changes.
5. Set or reset both IPv4 and IPv6 deliberately, verify both families, and surface loss
   of connectivity as a risk/restart diagnostic.
6. Decide how disconnected adapters are handled. "Currently up" is not a stable desired
   selector for laptops, docks, VPNs, or Wi-Fi/Ethernet switching.

## Services recommendation

A generic service plugin is useful infrastructure, but service configuration must be
explicit:

```yaml
system:
  windows:
    services:
      MapsBroker:
        startup: manual
```

It should support `automatic`, `automatic_delayed`, `manual`, `disabled`, and
`not_configured` only where semantics are well defined. Planning must record service
existence, start type, delayed-auto state, running state when relevant, and any trigger
start configuration that makes a simple start type misleading.

Do not ship WinUtil's five-service "Minimal" preset. Its name suggests safety that the
bundle cannot guarantee, and WinUtil's keep-current-startup heuristic means the same
preset produces different outcomes depending on whether a service still matches a
hard-coded assumed original value.

## Offline ISO/MicroWin assessment

Do not adopt WinUtil's ISO workflow into `winix-cfg`. It is effectively a separate image
customization product: it mounts and exports WIMs, removes provisioned AppX packages,
injects drivers, edits offline hives, generates unattended setup, builds bootable media,
and can bypass CPU/RAM/Secure Boot/storage/TPM checks. It also injects broad policy such
as blocking Windows Update through a localhost WSUS endpoint.

If Winix later needs image authoring, design it as a separate `winix-image` tool with:

- Input image hashing and immutable-source guarantees.
- Edition/index selection and explicit output manifests.
- A supported-vs-unsupported modification classification.
- Offline applicability tests per Windows build.
- Reproducible package/feature/driver inventories.
- Mount cleanup and recovery after interruption.
- No application removals unless explicitly configured by exact identity.
- No hardware-requirement bypass or update blocking in default profiles.

The online desired-state plugins proposed in this report should not assume their
registry paths can simply be rewritten against mounted offline hives; offline servicing
has different profiles, control sets, applicability, and first-logon semantics.

## Presets and profiles

WinUtil's Standard and Minimal presets include its service and telemetry bundles; the
Standard preset also performs cleanup and creates a restore point. Those are not stable
declarative profiles.

For Winix:

- Keep every setting explicit in the effective plan.
- Provide commented example YAML files such as `privacy-conscious.yaml` or
  `developer-workstation.yaml`, not opaque built-in preset names.
- Never allow a profile name to hide destructive actions.
- Let normal device overlays customize a profile.
- Validate profile conflicts through the existing schema/merge engine.
- Do not automatically add application removals to a system profile.

## Implementation roadmap

### Phase 0: safety primitives

1. Add type- and presence-aware registry helpers and tests.
2. Add native command execution/result helpers and tests.
3. Establish plugin test fixtures/mocking conventions for Windows state observation.
4. Define `not_configured`, applicability diagnostics, and restart metadata conventions.
5. Decide whether exact pre-Winix rollback receipts are required. Declarative inverse
   state is sufficient for most preferences; exact restoration requires durable,
   versioned receipts and ownership rules.

Exit criteria: a plugin can plan set/remove operations, detect a stale plan, apply, and
prove the registry type/value/absence postcondition without swallowing failures.

### Phase 1: high-value, low-blast-radius settings

1. Extend taskbar: battery percentage and End Task.
2. Add Explorer: file extensions, hidden files, and launch target.
3. Add theme: app/system light mode and scrollbars.
4. Add system behavior: long paths, verbose logon, detailed crash screen, window
   snapping, and mouse acceleration.
5. Add experience/privacy leaves: consumer features, activity history, advertising ID,
   tailored experiences, and feedback frequency.

Exit criteria: system/user scope tests, no-op plans, stale plans, remove-policy plans,
postconditions, and Explorer/reboot metadata all pass on supported Windows 11 VMs.

### Phase 2: system providers

1. Optional Windows features.
2. DNS with stable adapter selectors.
3. Delivery Optimization semantic modes.
4. Hibernation/power modes.
5. Explicit service resources, without a default service list.

Exit criteria: feature dependencies and reboot handling, DHCP/static DNS round trips,
service delayed-auto behavior, and unsupported/missing resources are tested.

### Phase 3: policy-rich and compatibility-sensitive features

1. Windows Update policy.
2. Location/privacy components.
3. Reserved Storage and Storage Sense.
4. OpenSSH server with security-focused schema.
5. Advanced Explorer, visual-effect, networking, and hardware-workaround settings.

Exit criteria: supported Windows editions/builds are documented and tested; every
advanced setting has a diagnostic explaining material consequences.

### Phase 4: action subsystem, if desired

Design a separate action protocol before adding restore points, cleanup, SFC/DISM,
network reset, or targeted Windows Update repair. Required properties include preview,
confirmation, progress, cancellation, timeout, partial-result reporting, reboot state,
and destructive-risk level.

## Testing strategy

Static unit tests are necessary but insufficient. WinUtil's tests verify JSON shape,
PowerShell parsing, and dispatch behavior; they generally do not prove that a registry
recipe is supported on a current Windows build or reaches its intended user-visible
state.

For each Winix resource:

1. Unit-test schema, state normalization, planned operation shape, and inverse/removal.
2. Unit-test stale-plan detection and failures from every mutation helper.
3. Run VM integration tests from both default and non-default starting states.
4. Test Windows 11 Pro and Enterprise where policy edition support differs.
5. Test user resources from a standard unelevated account and system resources only in
   the elevated worker.
6. Re-run plan after apply and require an empty operation list.
7. Apply the opposite or `not_configured` state and verify the documented rollback.
8. Test reboot-required resources across an actual reboot before declaring convergence.
9. Test interaction with Group Policy/MDM where practical; report external management
   instead of fighting it.

## Licensing and provenance

WinUtil is MIT-licensed; see [`LICENSE`](../../.research/winutil/LICENSE). Reimplementing
documented Windows behavior from semantic requirements is preferable to copying its
PowerShell wholesale. If substantial WinUtil code or configuration is copied, retain
the required copyright and MIT permission notice in the distributed source and record
the upstream commit. Keep a small provenance note for recipes derived from WinUtil even
when rewritten, because it makes future security and compatibility review easier.

## External validation sources

The following current Microsoft sources informed the risk and compatibility judgments:

- [Configure Delivery Optimization](https://learn.microsoft.com/en-us/windows/deployment/do/delivery-optimization-configure)
  and [Delivery Optimization Policy CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-DeliveryOptimization):
  mode `0` is HTTP-only/no peering, not "Delivery Optimization disabled"; mode `100` is
  deprecated on Windows 11.
- [Add, remove, or hide Windows features](https://learn.microsoft.com/en-us/windows/client-management/client-tools/add-remove-hide-features):
  supported optional-feature observation and enable/disable surfaces.
- [Windows Privacy Compliance Guide](https://learn.microsoft.com/en-us/windows/privacy/windows-privacy-compliance-guide)
  and [Configure Windows diagnostic data](https://learn.microsoft.com/en-us/windows/privacy/configure-windows-diagnostic-data-in-your-organization):
  current policy names, diagnostic levels, and privacy-setting distinctions.
- [Experience Policy CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-experience):
  consumer-feature policy scope, editions, and supported mapping.
- [Configure IPv6 for advanced users](https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/configure-ipv6-in-windows):
  Microsoft warns against disabling IPv6 and documents the `DisabledComponents` masks.
- [How to disable and re-enable hibernation](https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/disable-and-re-enable-hibernation)
  and [System power states](https://learn.microsoft.com/en-us/windows/win32/power/system-power-states):
  disabling hibernation also removes hybrid sleep/hibernation-file-dependent behavior,
  including Fast Startup.
- [BitLocker operations guide](https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/operations-guide):
  disabling BitLocker decrypts the volume and removes protectors; it is not a benign
  optimization.

## Final recommendation

Use WinUtil as a maintained research input, not a dependency and not a source of default
presets. Port the intent of selected settings into Winix's stronger plan/apply model,
one semantic resource at a time. Start with the Phase 1 list, then optional features,
DNS, Delivery Optimization, and power. Keep application removal explicit in the package
plugins and keep destructive repairs out of declarative configuration.
