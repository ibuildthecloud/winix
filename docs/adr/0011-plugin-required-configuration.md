# ADR 0011: Plugin-required configuration

## Status

Accepted

## Context

Some providers depend on resources that Winix can itself manage. In particular, the WinGet provider will use the `Microsoft.WinGet.Client` PowerShell module, and a PowerShell-module provider can install that module. A dependent plugin cannot reliably report a missing prerequisite at runtime because the prerequisite may be necessary merely to load or execute the plugin. Installing prerequisites during planning would also violate the side-effect-free closed-plan model.

## Decision

A plugin manifest may include a `requires.configuration` object. It is a configuration fragment relative to each scope where the dependent plugin is configured.

Winix recursively merges required fragments into the effective configuration after device overlays are resolved. It does not modify the source configuration file. Equal or complementary object values merge; conflicting explicit values fail before provider validation or planning.

Plugin discovery derives dependencies from plugin paths present in required fragments and topologically orders providers before dependents. Provider operations are planned first. Their operation IDs are added to every operation produced by the dependent plugin, so the global plan validator and apply order enforce the dependency.

System and user requirements remain distinct. A system dependency is reconciled in the system placement and a current-user dependency in the user placement.

Planning remains side-effect free. If a dependency is required for provider observation as well as mutation, the provider must offer a bootstrap observation path until the dependency has been applied. A plan never installs a missing prerequisite merely to continue planning.

## Consequences

- Implicit prerequisites are visible as ordinary concrete operations in the complete plan.
- Apply cannot run a dependent mutation before a planned prerequisite mutation.
- Explicit configuration cannot remove or pin a resource incompatibly with a plugin requirement.
- Transitive required configuration is supported and dependency cycles are rejected.
- Both system and user declarations may install the same resource in their respective native scopes; Winix does not collapse those distinct ownership boundaries.
