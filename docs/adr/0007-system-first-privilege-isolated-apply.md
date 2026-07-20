# ADR 0007: System-first privilege-isolated plan and apply

- Status: Accepted
- Date: 2026-07-20
- Decision owners: Winix maintainers
- Supersedes: The `--all` ordering and unqualified plan/apply scope defaults in ADR 0002

## Context

ADR 0002 separated user and system execution into unelevated and elevated processes, but initially ordered `apply --all` as user configuration followed by system configuration. That ordering can make user changes before the user sees or approves UAC, and a rejected UAC request leaves a partially applied operation.

User configuration must never run with elevated privileges. An arbitrary token selected from another process risks selecting the wrong user profile, session, or `HKCU` hive.

## Decision

When `winix-cfg` starts unelevated, its coordinator remains unelevated for its entire lifetime. An unqualified `plan` or `apply` selects only `users.current`. `--system` and `--all` request UAC before system state inspection. For apply, the elevated worker plans and applies the system scope under one token. After it exits successfully, an `--all` coordinator plans and applies current-user state unelevated. Planning uses the same privilege split but returns both plans without mutation.

When effective system configuration exists, execution is:

```text
unelevated coordinator
    -> request UAC
    -> elevated worker plans and applies system only
    -> wait for successful completion
    -> original coordinator plans and applies users.current unelevated
```

In that flow, the coordinator does not drop privileges because it never acquires them. Elevation exists only in the dedicated system worker.

When `winix-cfg` starts elevated under Windows Sudo, Run as administrator, or another UAC split-token launch, an unqualified `plan` or `apply` defaults to both scopes and execution is:

```text
elevated coordinator
    -> plan and apply system directly
    -> verify the same-session desktop shell identity and elevation
    -> Task Scheduler launches an InteractiveToken, least-privilege worker
    -> worker plans and applies users.current
    -> wait for successful completion
```

If UAC is rejected or system application fails, user application does not begin. If system application succeeds but user application later fails, system changes remain; rollback remains outside the current design.

If effective system configuration is empty, the system phase skips UAC and processes `users.current` normally.

The command behaviors are:

| Selection | Unelevated coordinator | Elevated coordinator |
| --- | --- | --- |
| no scope flag | user | system, then user |
| `--user` | user | user in limited worker |
| `--system` | system through UAC | system |
| `--all` | system through UAC, then user | system, then user in limited worker |

The table applies equally to `plan` and `apply`. The three scope flags are mutually exclusive.

When the original coordinator is already elevated, it applies the system phase directly. Before the user phase, Winix verifies that the current window station's desktop shell belongs to the coordinator's Windows session and user SID and is not elevated. It then registers a uniquely named, triggerless Task Scheduler task for that SID using `InteractiveToken` logon and `LeastPrivilege` run level, starts it immediately, waits for the worker result, and removes the task. The task enters through the GUI-subsystem Windows Script Host and launches the console-subsystem Winix worker with hidden window style from process creation, avoiding a transient console window. The user worker independently rejects an elevated token. Winix never selects an arbitrary process, session, or another user's token. If no matching unelevated desktop shell exists, the operation is rejected before mutation; `apply --system` remains available.

The selected step sequence is represented explicitly and covered by unit tests so future refactoring cannot silently reverse the privilege boundary ordering.

## Consequences

### Positive

- UAC approval occurs before any `--all` changes.
- UAC approval occurs before potentially slow system provider inspection.
- Rejecting UAC leaves user configuration untouched.
- User plugins always retain the original interactive user's token and profile.
- System and user privileges remain isolated by process.
- `sudo winix-cfg apply --all` can reuse the caller's verified desktop session without a second UAC prompt.
- Ordering is explicit and testable.

### Negative

- A later user failure can leave already-applied system changes.
- `--all` waits for the elevated worker before beginning user work.
- A limited worker requires an interactive desktop shell for the same user and session.
