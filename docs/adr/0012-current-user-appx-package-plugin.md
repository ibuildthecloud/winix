# ADR 0012: AppX package removal plugin

- Status: Accepted
- Date: 2026-07-19
- Decision owners: Winix maintainers

## Context

Many Windows and OEM applications are AppX/MSIX packages that WinGet cannot correlate to a canonical catalog identifier. Treating their `MSIX\...` inventory identifiers as WinGet package IDs fails validation and gives the wrong plugin ownership.

AppX has separate current-user registration and machine provisioning concepts. Removing a current user's package does not remove the provisioned package for future users. System provisioning also requires elevation, while the primary Winix use case is a laptop's current user.

## Decision

The `appx` plugin registers at `packages.appx` for system and user placement. Resource-map keys are exact, case-sensitive AppX `Name` values. `PackageFullName`, which contains version and architecture, is observed state rather than resource identity.

The first implementation supports `state: absent` only. User apply rejects stale plans, removes only the current user's exact packages, runs unelevated, and verifies absence.

A system declaration means that the package is absent from every existing user and from machine provisioning for future users. System planning uses the readable AppX registry because the authoritative inventory cmdlets require elevation. Elevated apply re-observes state with `Get-AppxPackage -AllUsers` and `Get-AppxProvisionedPackage -Online`, removes registrations and provisioning, and verifies both postconditions. Registry observations are never used as mutation targets.

Installed-state creation is deferred.

MSI/ARP companion services are separate resources and are not removed as side effects of AppX operations.

## Consequences

- OEM and Store apps can be removed declaratively without pretending they are WinGet catalog packages.
- Package identity remains stable across AppX version updates.
- Current-user removal is privilege-isolated and deterministic.
- System absence covers existing registrations and future-user provisioning and requires elevation.
- OEM companion services require a Windows Installer/ARP plugin or another explicitly owned system resource.
