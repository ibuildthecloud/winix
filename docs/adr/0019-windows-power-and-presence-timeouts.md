# ADR 0019: Windows 11 power and presence timeouts

- Status: Accepted
- Date: 2026-07-20

## Context

Current Windows 11 consumer devices can reach screen-off through two distinct paths. Ordinary inactivity uses the active power scheme's display idle timeout. Compatible Windows 11 devices also expose Presence Sensing, including Adaptive Dimming when the user looks away and Lock on Leave when the user moves away. Presence behavior has separate AC and battery timeout values in the active power scheme.

The older `Interactive logon: Machine inactivity limit` is an administrative security-policy surface. It does not represent the Windows 11 Home consumer experience and is outside Winix's edition baseline. Likewise, the legacy generic `Dim display after` timeout is no longer the modern dimming experience; Windows 11 Adaptive Dimming is driven by a presence sensor.

Power scheme names and `powercfg /query` labels are localized. The active scheme can also change between planning and applying.

## Decision

The system-only `windows.power` plugin manages the active Windows 11 power scheme through native power-management APIs. It exposes the ordinary `display_off_after` timeout and these Presence Aware Power Behavior timeouts beneath `presence_sensing`:

- `inattentive_dim_after`
- `inattentive_display_off_after`
- `away_dim_after`
- `away_display_off_after`

Every timeout supports independent `plugged_in_seconds` and `on_battery_seconds` values. Zero disables the timeout, and omitted properties remain unmanaged. Presence settings have an effect only on hardware with a compatible sensor and when the user has enabled the Windows 11 Presence Sensing consumer feature.

Each planned operation binds the active scheme GUID, native setting identity, power source, and observed timeout as structured preconditions. Apply preflights the entire queue with JSON-semantic comparison, rejects scheme or value drift, writes only approved values, reactivates the scheme, and verifies each postcondition.

Winix does not expose the machine inactivity security policy as an automatic-lock setting. Lock on Leave is represented by its Windows 11 consumer outcome, `away_display_off_after`; Windows turns off the display as part of the presence-driven lock experience.

## Consequences

- Configuration follows the latest Windows 11 Home Settings model rather than an enterprise policy model.
- Adaptive Dimming and Lock on Leave can be tuned on supported consumer hardware.
- Changing the active power scheme invalidates a saved plan; a new plan targets the newly active scheme.
- Presence privacy consent, sensor distance, wake on approach, external-display behavior, sleep, and locked-console display-off timing remain outside the plugin's current ownership.
