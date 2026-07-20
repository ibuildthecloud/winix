# ADR 0020: Windows support baseline

- Status: Accepted
- Date: 2026-07-20

## Context

Winix is a consumer-oriented configuration tool for individual users, open-source developers, and similar personal Windows environments. Supporting old Windows releases and administrative edition features would add branches, fallback mappings, and testing obligations while steering the configuration model away from the experience its users actually see.

Windows Insider builds can preview a consumer surface before it reaches general availability. Supporting an Insider build alongside the current public release can be useful, but it is a forward-compatibility case rather than a reason to preserve historical implementations.

## Decision

Winix targets the latest generally available Windows 11 Home release. Public configuration models the current consumer-facing Windows experience and must not depend on Pro/Enterprise-only Group Policy, MDM/CSP, domain, or organizational-management capabilities.

Winix does not add legacy Windows version branches or fallback registry mappings by default. When Windows changes a surface, the implementation moves forward with the current generally available release.

An active Windows Insider build may be supported deliberately alongside the generally available release. Prefer runtime capability detection and shared outcome semantics when the two builds expose different mechanisms. A temporary build distinction is acceptable only when capability detection cannot safely distinguish them, and it should be removed once the older path is no longer the generally available baseline.

## Consequences

- Windows 10, older Windows 11 releases, Windows Server, and enterprise-only management surfaces are not compatibility targets.
- Plugins can be simpler and can use current Windows 11 terminology and behavior.
- Unsupported hardware capabilities are still detected and reported where a setting depends on them; edition compatibility does not imply every Home device has identical hardware.
- Contributors must verify current generally available behavior before copying older registry or policy recipes.
