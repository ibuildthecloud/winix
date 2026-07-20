# Winix examples

Examples are executable configurations, not inert documentation. Always validate and plan a configuration before applying it.

## `quickstart.yaml`

This is the safe introductory configuration used by the root README. It manages only the current user's desktop icon visibility. It neither installs nor removes software and does not require elevation:

```powershell
cargo run -- validate examples/quickstart.yaml
cargo run -- plan examples/quickstart.yaml --user
cargo run -- apply examples/quickstart.yaml --user
```

Applying it again after convergence should produce an empty plan.

## `workstation.yaml`

> [!CAUTION]
> This is a destructive and opinionated reference profile. It removes AppX packages including Microsoft Store, removes Start menu shortcuts and OEM pin declarations, and uses an exhaustive taskbar layout that removes unlisted pins. It is not intended for blind copy-and-paste use.

Inspect every operation before adapting this profile to a real workstation. In particular, every `state: absent`, shortcut entry, package identity, and exhaustive collection is explicit destructive intent.
