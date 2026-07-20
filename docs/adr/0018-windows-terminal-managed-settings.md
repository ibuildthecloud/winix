# ADR 0018: Manage selected Windows Terminal settings semantically

## Status

Accepted

## Context

Windows Terminal stores current-user configuration in `settings.json`, mixed
with generated profile entries and settings owned by the user or Terminal. A
whole-file declaration would erase unrelated state. Profile GUIDs are stable on
a machine but are awkward and unnecessarily machine-specific in portable
configuration. Actions and keybindings are collections without a natural Winix
receipt.

## Decision

`applications.windows_terminal` is a user-only plugin. It manages selected
global properties, profile defaults and overrides, and keybindings while
preserving unrelated JSON properties and profiles.

Profile configuration uses explicit `guid:`, `name:`, and `source:` selectors.
The default-profile selector must resolve to exactly one profile and is written
as Terminal's GUID. Override source selectors may intentionally update multiple
generated profiles.

Winix-created actions use the reserved `Winix.` ID prefix. The configured
keybinding map is exhaustive only for that prefix, but a configured key
combination supersedes any existing binding for the same keys. This gives Winix
a safe ownership boundary without claiming all user actions.

Planning parses the complete file, applies the selected semantic overlay, and
emits one closed write operation containing the exact resulting content. Apply
preflights the original file length and SHA-256 before any mutation, writes a
temporary file in the same directory, atomically replaces `settings.json`, and
verifies the planned postcondition. Concurrent Terminal or user edits therefore
produce a stale-plan failure instead of being silently overwritten.

The stable Store package and unpackaged stable path are recognized. Preview is
not selected implicitly because managing multiple Terminal installations from
one declaration would be ambiguous.

## Consequences

The plugin rewrites JSON formatting and comments, although JSON semantics and
unmanaged properties are retained. Windows Terminal must have been launched at
least once so its profile inventory exists. Newly requested settings require a
new Terminal window to be observed reliably.
