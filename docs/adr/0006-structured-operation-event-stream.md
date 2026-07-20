# ADR 0006: Structured operation event stream

- Status: Accepted
- Date: 2026-07-19
- Decision owners: Winix maintainers

## Context

Plugins perform operations that may take significant time and affect multiple resources. Printing human-formatted messages directly from PowerShell would couple plugins to the terminal UX, prevent consistent rendering, and make it difficult for a future GUI to observe progress.

The initial plugin protocol returned one JSON document after the PowerShell process exited. This provided an authoritative result but no incremental visibility into inspection, validation, package installation, or other long-running work.

Rust already supervises plugin processes and owns trusted context such as plugin identity, configuration path, scope, device, and operation selection. It should remain the boundary between plugin-produced data and user-facing presentation.

## Decision

### PowerShell transport

A plugin receives one versioned JSON request on standard input and writes a stream of newline-delimited JSON records to standard output. Each record occupies exactly one line and has a `type` discriminator.

Event record:

```json
{"type":"event","kind":"resource_checking","resource":{"type":"winget.package","id":"Git.Git"},"data":{}}
```

Final result record:

```json
{"type":"result","result":{"changed":false,"restart_required":{"explorer":false,"system":false}}}
```

A plugin may emit zero or more event records and must emit exactly one final result. It must not emit records after the result. Ordinary PowerShell or native-command output must not be written to standard output. Unexpected process-level information may be written to standard error.

The final result is authoritative. Events are transient observations and are not used to reconstruct the result.

### Engine events

Rust validates plugin records, enriches them with trusted metadata, assigns ordering, and broadcasts a unified engine event. An engine event includes the protocol version, operation ID, monotonically increasing sequence number, receipt timestamp, event kind, plugin path, scope, device context, and structured payload.

Plugins do not control trusted engine metadata. Rust also originates lifecycle and failure events when starting operations and plugins, completing them, or observing protocol/process failures.

The initial event vocabulary is:

- `operation_started` and `operation_completed`;
- `plugin_started`, `plugin_completed`, and `plugin_failed`;
- `resource_checking` and `resource_status`;
- `resource_change_started` and `resource_change_completed`;
- `progress`;
- `diagnostic`;
- `restart_required`.

Event payloads remain JSON-compatible. Resource events contain a domain resource type and semantic identity. Status, action, severity, and diagnostic code values are machine-readable enums rather than terminal prose.

### Diagnostics

Diagnostics contain a stable code and structured data in addition to human-readable text. Consumers treat codes and data as the stable interface. Human text may evolve or eventually be localized. Plugins must avoid placing secrets in events or diagnostics.

### Event consumers

The Rust engine exposes an event-sink abstraction. The initial sinks are a human-oriented console renderer, an NDJSON renderer suitable for automation and a future GUI, and an in-memory collector used by tests.

CLI operations accept `--output console` and `--output ndjson`, with console output as the default. Plugins never produce ANSI styling or console layout.

An elevated system worker runs without a visible transient console and always writes raw NDJSON `EngineEvent` records to a per-operation transport file. It never formats console output. After the elevated phase exits, the original coordinator parses those records and forwards them to its own selected console or NDJSON sink. Worker failures are structured `operation_failed` events in the same transport. This initial forwarding is buffered rather than live; authenticated live forwarding to a parent CLI or GUI remains deferred to the hardened IPC design.

### Progress

Progress is determinate only when the underlying operation provides meaningful completed and total units. Otherwise plugins emit phase transitions or indeterminate progress. Plugins must not invent percentages for operations such as WinGet installation when WinGet does not expose trustworthy structured progress.

### Failure behavior

Malformed JSON, an unknown record type, duplicate results, output after the result, a missing result, or a nonzero plugin exit is a protocol failure. Rust emits `plugin_failed` and fails the operation. Standard error is included in bounded diagnostic data but is not treated as a protocol stream.

## Consequences

### Positive

- The CLI and future GUI consume the same structured operation model.
- Long-running plugin work becomes observable incrementally.
- Console presentation can evolve independently from plugin implementations.
- NDJSON supports logging, automation, and subprocess-based GUI integration.
- Rust controls trusted metadata and consistent failure reporting.

### Negative

- Plugin stdout becomes a strict framed protocol and accidental output is fatal.
- Rust must read stdout and stderr concurrently to avoid process deadlocks.
- Event schemas and vocabulary become a versioned public interface.
- Elevated event forwarding is buffered until the system phase exits rather than streamed live.

## Deferred decisions

- Authenticated event and result IPC across the UAC boundary.
- Cancellation and interactive plugin requests.
- Persistent event logs and replay.
- Localization of human diagnostic text.
- Event vocabulary compatibility beyond protocol version 1.
- Multiple simultaneous plugin execution and cross-plugin ordering.
