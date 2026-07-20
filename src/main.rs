mod config;
mod device;
mod engine;
mod event;
mod paths;
mod plugin;
mod powershell;
mod schema;

use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use base64::Engine;
use clap::{Parser, Subcommand};
use event::{EventEmitter, OutputFormat, operation_payload};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Debug, Parser)]
#[command(name = "winix-cfg", version, about)]
struct Cli {
    /// Directory containing plugin manifests.
    #[arg(long, global = true)]
    plugins_dir: Option<PathBuf>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Generate the combined JSON Schema for all discovered plugins.
    Schema {
        /// Write the schema to this file instead of standard output.
        #[arg(short, long)]
        output: Option<PathBuf>,
    },
    /// Validate a configuration document without inspecting Windows.
    Validate {
        config: Option<PathBuf>,
        #[arg(long, value_enum, default_value_t)]
        output: OutputFormat,
    },
    /// List discovered plugins and their registered paths.
    Plugins,
    /// Inspect current state for configured plugins without making changes.
    Inspect {
        config: Option<PathBuf>,
        #[arg(long, value_enum, default_value_t)]
        output: OutputFormat,
    },
    /// Build a concrete operation queue without making changes.
    Plan {
        config: Option<PathBuf>,
        /// Plan both users.current and system configuration.
        #[arg(long, conflicts_with_all = ["system", "user"])]
        all: bool,
        /// Plan only system configuration, requesting elevation if needed.
        #[arg(long, conflicts_with = "user")]
        system: bool,
        /// Plan only users.current configuration.
        #[arg(long)]
        user: bool,
        #[arg(long, value_enum, default_value_t)]
        output: OutputFormat,
    },
    /// Validate and apply the requested configuration.
    Apply {
        config: Option<PathBuf>,
        /// Apply both users.current and system configuration.
        #[arg(long, conflicts_with_all = ["system", "user"])]
        all: bool,
        /// Apply only system configuration, requesting UAC elevation if needed.
        #[arg(long, conflicts_with = "user")]
        system: bool,
        /// Apply only users.current configuration.
        #[arg(long)]
        user: bool,
        /// Select human console events or machine-readable NDJSON.
        #[arg(long, value_enum, default_value_t)]
        output: OutputFormat,
    },
    /// Internal entrypoint for the elevated system worker.
    #[command(name = "elevated-operation", hide = true)]
    ElevatedOperation { payload: String },
    /// Internal entrypoint for a current-user worker launched at limited privilege.
    #[command(name = "user-operation", hide = true)]
    UserOperation { request: PathBuf },
}

#[derive(Debug, Serialize, Deserialize)]
struct ElevatedRequest {
    plugins_dir: PathBuf,
    system: Value,
    plan: Value,
    device: device::DeviceContext,
    capture_path: PathBuf,
    result_path: PathBuf,
    operation: WorkerOperation,
}

#[derive(Debug, Serialize, Deserialize)]
struct UserRequest {
    plugins_dir: PathBuf,
    user: Value,
    device: device::DeviceContext,
    capture_path: PathBuf,
    result_path: PathBuf,
    status_path: PathBuf,
    powershell: PathBuf,
    operation: WorkerOperation,
    prior_operations: Vec<Value>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum WorkerOperation {
    Plan,
    Apply,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ApplyStep {
    System,
    User,
}

fn main() {
    match run() {
        Ok(0) => {}
        Ok(code) => std::process::exit(code),
        Err(error) => {
            let rendered = format!("error: {error:#}");
            eprintln!("{rendered}");
            std::process::exit(1);
        }
    }
}

fn run() -> Result<i32> {
    let cli = Cli::parse();
    if let Command::UserOperation { request } = &cli.command {
        return run_user(request).map(|restart_required| {
            if restart_required {
                powershell::REBOOT_REQUIRED_EXIT_CODE
            } else {
                0
            }
        });
    }
    powershell::ensure_available()?;
    if let Command::ElevatedOperation { payload } = &cli.command {
        return run_elevated(payload.clone()).map(|restart_required| {
            if restart_required {
                powershell::REBOOT_REQUIRED_EXIT_CODE
            } else {
                0
            }
        });
    }

    let plugins_dir = paths::plugins(cli.plugins_dir.clone())?;
    let plugins = plugin::discover(&plugins_dir)?;

    let mut exit_code = 0;
    match cli.command {
        Command::Schema { output } => {
            let schema = schema::compose(&plugins)?;
            let rendered = serde_json::to_string_pretty(&schema)?;
            if let Some(path) = output {
                std::fs::write(&path, format!("{rendered}\n"))?;
                println!("wrote {}", path.display());
            } else {
                println!("{rendered}");
            }
        }
        Command::Validate { config, output } => {
            let mut events = EventEmitter::new(output);
            events.emit("operation_started", operation_payload("validate", None));
            let path = paths::config(config)?;
            let document = config::load(&path)?;
            engine::validate_document(&document, &plugins)?;
            let resolved = device::resolve(&document)?;
            let effective_document =
                plugin::with_required_configuration(&resolved.document, &plugins)?;
            engine::validate_document(&effective_document, &plugins)?;
            engine::validate_plugins(
                &effective_document,
                &plugins,
                &[engine::Scope::UserCurrent, engine::Scope::System],
                &resolved.context,
                &mut events,
            )?;
            events.emit(
                "operation_completed",
                operation_payload("validate", Some(json!({ "valid": true, "config": path }))),
            );
        }
        Command::Plugins => {
            for plugin in plugins {
                let placements = plugin
                    .manifest
                    .placements
                    .iter()
                    .map(|placement| format!("{placement:?}").to_ascii_lowercase())
                    .collect::<Vec<_>>()
                    .join(",");
                let requirements = &plugin.manifest.requires;
                let powershell = requirements.powershell.as_deref().unwrap_or("any");
                let commands = if requirements.commands.is_empty() {
                    "-".to_owned()
                } else {
                    requirements.commands.join(",")
                };
                println!(
                    "{}\t{}\t{}\tpowershell={}\tadministrator={}\tcommands={}\trequired_config={}",
                    plugin.manifest.path,
                    placements,
                    plugin.manifest.name,
                    powershell,
                    requirements.administrator,
                    commands,
                    requirements.configuration.is_some()
                );
            }
        }
        Command::Inspect { config, output } => {
            let mut events = EventEmitter::new(output);
            events.emit("operation_started", operation_payload("inspect", None));
            let path = paths::config(config)?;
            let document = config::load(&path)?;
            engine::validate_document(&document, &plugins)?;
            let resolved = device::resolve(&document)?;
            let effective_document =
                plugin::with_required_configuration(&resolved.document, &plugins)?;
            engine::validate_document(&effective_document, &plugins)?;
            if powershell::is_elevated()? {
                bail!("current-user inspection must be run from a non-elevated terminal");
            }
            let result = engine::plan(
                &effective_document,
                &plugins,
                engine::Scope::UserCurrent,
                &resolved.context,
                &mut events,
            )?;
            events.emit(
                "operation_completed",
                operation_payload("inspect", Some(result)),
            );
        }
        Command::Plan {
            config,
            all,
            system,
            user,
            output,
        } => {
            let mut events = EventEmitter::new(output);
            events.emit("operation_started", operation_payload("plan", None));
            let path = paths::config(config)?;
            let document = config::load(&path)?;
            engine::validate_document(&document, &plugins)?;
            let resolved = device::resolve(&document)?;
            let effective_document =
                plugin::with_required_configuration(&resolved.document, &plugins)?;
            engine::validate_document(&effective_document, &plugins)?;
            let elevated = powershell::is_elevated()?;
            let mut user_result = Value::Null;
            let mut system_result = Value::Null;
            let steps = scope_steps(all, system, user, elevated);
            if elevated && steps.contains(&ApplyStep::User) {
                powershell::ensure_unelevated_worker_available()?;
            }
            for step in steps {
                match step {
                    ApplyStep::System => {
                        system_result = if elevated {
                            engine::plan(
                                &effective_document,
                                &plugins,
                                engine::Scope::System,
                                &resolved.context,
                                &mut events,
                            )?
                        } else {
                            run_system_elevated(
                                &effective_document,
                                &resolved.context,
                                &plugins_dir,
                                &mut events,
                                WorkerOperation::Plan,
                                &Value::Null,
                            )?
                        };
                    }
                    ApplyStep::User => {
                        let prior_operations = engine::planned_operations(&system_result);
                        user_result = if elevated {
                            run_user_unelevated(
                                &effective_document,
                                &resolved.context,
                                &plugins_dir,
                                &mut events,
                                WorkerOperation::Plan,
                                prior_operations,
                            )?
                        } else {
                            engine::plan_with_prior_operations(
                                &effective_document,
                                &plugins,
                                engine::Scope::UserCurrent,
                                &resolved.context,
                                &mut events,
                                &prior_operations,
                            )?
                        };
                    }
                }
            }
            engine::validate_plan_sequence(&[&system_result, &user_result])?;
            let restart_pending = engine::system_restart_pending(&system_result)
                || engine::system_restart_pending(&user_result);
            events.emit(
                "operation_completed",
                operation_payload(
                    "plan",
                    Some(json!({ "user": user_result, "system": system_result })),
                ),
            );
            if restart_pending {
                events.emit(
                    "restart_required",
                    json!({
                        "reason": "pending_system_restart",
                        "exit_code": powershell::REBOOT_REQUIRED_EXIT_CODE,
                        "message": "System restart required. Configuration is not yet converged. Restart Windows, then run Winix again to continue."
                    }),
                );
                exit_code = powershell::REBOOT_REQUIRED_EXIT_CODE;
            }
        }
        Command::Apply {
            config,
            all,
            system,
            user,
            output,
        } => {
            let mut events = EventEmitter::new(output);
            events.emit("operation_started", operation_payload("apply", None));
            let path = paths::config(config)?;
            let document = config::load(&path)?;
            engine::validate_document(&document, &plugins)?;
            let resolved = device::resolve(&document)?;
            let effective_document =
                plugin::with_required_configuration(&resolved.document, &plugins)?;
            engine::validate_document(&effective_document, &plugins)?;
            let elevated = powershell::is_elevated()?;

            let steps = scope_steps(all, system, user, elevated);
            if elevated && steps.contains(&ApplyStep::User) {
                powershell::ensure_unelevated_worker_available()?;
            }
            let mut user_result = Value::Null;
            let mut system_result = Value::Null;
            for step in steps {
                match step {
                    ApplyStep::System => {
                        if elevated {
                            let system_plan = engine::plan(
                                &effective_document,
                                &plugins,
                                engine::Scope::System,
                                &resolved.context,
                                &mut events,
                            )?;
                            engine::validate_plan_sequence(&[&system_plan])?;
                            system_result = apply_system(
                                &effective_document,
                                &resolved.context,
                                &plugins_dir,
                                &plugins,
                                true,
                                &mut events,
                                &system_plan,
                            )?;
                        } else {
                            // Elevate before inspecting system state. The worker
                            // builds and applies its plan under the same token,
                            // so --all requests UAC before potentially slow
                            // WinGet/AppX inventory and prompts only once.
                            system_result = apply_system(
                                &effective_document,
                                &resolved.context,
                                &plugins_dir,
                                &plugins,
                                false,
                                &mut events,
                                &Value::Null,
                            )?;
                        }
                    }
                    ApplyStep::User => {
                        if elevated {
                            user_result = run_user_unelevated(
                                &effective_document,
                                &resolved.context,
                                &plugins_dir,
                                &mut events,
                                WorkerOperation::Apply,
                                vec![],
                            )?;
                            continue;
                        }
                        // The system postconditions are already established, so
                        // user planning observes final machine state directly.
                        let user_plan = engine::plan_with_prior_operations(
                            &effective_document,
                            &plugins,
                            engine::Scope::UserCurrent,
                            &resolved.context,
                            &mut events,
                            &[],
                        )?;
                        engine::validate_plan_sequence(&[&user_plan])?;
                        user_result = engine::apply_plan(
                            &effective_document,
                            &plugins,
                            engine::Scope::UserCurrent,
                            &resolved.context,
                            &mut events,
                            &user_plan,
                        )?;
                    }
                }
            }
            let restart_required = engine::system_restart_required(&system_result)
                || engine::system_restart_required(&user_result);
            events.emit(
                "operation_completed",
                operation_payload(
                    "apply",
                    Some(json!({ "user": user_result, "system": system_result })),
                ),
            );
            if restart_required {
                events.emit(
                    "restart_required",
                    json!({
                        "reason": "pending_system_restart",
                        "exit_code": powershell::REBOOT_REQUIRED_EXIT_CODE,
                        "message": "System restart required. Configuration is not yet converged. Restart Windows, then run Winix again to continue."
                    }),
                );
                exit_code = powershell::REBOOT_REQUIRED_EXIT_CODE;
            }
        }
        Command::ElevatedOperation { .. } | Command::UserOperation { .. } => unreachable!(),
    }

    Ok(exit_code)
}

fn run_user_unelevated(
    document: &Value,
    device: &device::DeviceContext,
    plugins_dir: &std::path::Path,
    events: &mut EventEmitter,
    operation: WorkerOperation,
    prior_operations: Vec<Value>,
) -> Result<Value> {
    let user = document
        .pointer("/users/current")
        .cloned()
        .unwrap_or_else(|| json!({}));
    if user.as_object().is_some_and(serde_json::Map::is_empty) {
        return Ok(json!({ "scope": "users.current", "results": {} }));
    }

    let capture_path = powershell::elevated_capture_path();
    let result_path = capture_path.with_extension("result");
    let status_path = capture_path.with_extension("status");
    let request_path = capture_path.with_extension("request");
    let request = UserRequest {
        plugins_dir: powershell_compatible_path(plugins_dir.canonicalize()?),
        user,
        device: device.clone(),
        capture_path: capture_path.clone(),
        result_path: result_path.clone(),
        status_path: status_path.clone(),
        powershell: powershell_compatible_path(powershell::ensure_available()?.to_path_buf()),
        operation,
        prior_operations,
    };
    std::fs::write(&request_path, serde_json::to_vec(&request)?)
        .context("failed to write current-user worker request")?;
    let apply = powershell::request_unelevated_apply(
        &std::env::current_exe()?,
        &request_path,
        &capture_path,
        &status_path,
        events,
    );
    let result = apply.and_then(|_| {
        let bytes = std::fs::read(&result_path)
            .context("current-user worker did not return its execution result")?;
        serde_json::from_slice(&bytes).context("current-user worker returned an invalid result")
    });
    if capture_path.is_file() {
        let _ = std::fs::remove_file(&capture_path);
    }
    if result_path.is_file() {
        let _ = std::fs::remove_file(&result_path);
    }
    if request_path.is_file() {
        let _ = std::fs::remove_file(&request_path);
    }
    let wrapper_path = request_path.with_extension("vbs");
    if wrapper_path.is_file() {
        let _ = std::fs::remove_file(&wrapper_path);
    }
    if status_path.is_file() {
        let _ = std::fs::remove_file(&status_path);
    }
    result
}

fn scope_steps(all: bool, system: bool, user: bool, elevated: bool) -> Vec<ApplyStep> {
    if all {
        vec![ApplyStep::System, ApplyStep::User]
    } else if system {
        vec![ApplyStep::System]
    } else if user || !elevated {
        vec![ApplyStep::User]
    } else {
        vec![ApplyStep::System, ApplyStep::User]
    }
}

fn apply_system(
    document: &Value,
    device: &device::DeviceContext,
    plugins_dir: &std::path::Path,
    plugins: &[plugin::Plugin],
    elevated: bool,
    events: &mut EventEmitter,
    plan: &Value,
) -> Result<Value> {
    let system = document.get("system").cloned().unwrap_or_else(|| json!({}));
    if system.as_object().is_some_and(serde_json::Map::is_empty) {
        return Ok(json!({ "scope": "system", "results": {} }));
    }

    if elevated {
        let result = engine::apply_plan(
            document,
            plugins,
            engine::Scope::System,
            device,
            events,
            plan,
        )?;
        return Ok(result);
    }

    run_system_elevated(
        document,
        device,
        plugins_dir,
        events,
        WorkerOperation::Apply,
        plan,
    )
}

fn run_system_elevated(
    document: &Value,
    device: &device::DeviceContext,
    plugins_dir: &std::path::Path,
    events: &mut EventEmitter,
    operation: WorkerOperation,
    plan: &Value,
) -> Result<Value> {
    let system = document.get("system").cloned().unwrap_or_else(|| json!({}));
    if system.as_object().is_some_and(serde_json::Map::is_empty) {
        return Ok(json!({ "scope": "system", "results": {} }));
    }

    let capture_path = powershell::elevated_capture_path();
    let result_path = capture_path.with_extension("result");
    let request = ElevatedRequest {
        plugins_dir: powershell_compatible_path(plugins_dir.canonicalize()?),
        system,
        plan: plan.clone(),
        device: device.clone(),
        capture_path: capture_path.clone(),
        result_path: result_path.clone(),
        operation,
    };
    let encoded =
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(serde_json::to_vec(&request)?);
    let apply = powershell::request_elevated_apply(
        &std::env::current_exe()?,
        &encoded,
        &capture_path,
        events,
    );
    let result = apply.and_then(|_| {
        let bytes = std::fs::read(&result_path)
            .context("elevated worker did not return its execution result")?;
        serde_json::from_slice(&bytes).context("elevated worker returned an invalid result")
    });
    if capture_path.is_file() {
        let _ = std::fs::remove_file(&capture_path);
    }
    if result_path.is_file() {
        let _ = std::fs::remove_file(&result_path);
    }
    result
}

fn powershell_compatible_path(path: PathBuf) -> PathBuf {
    let value = path.to_string_lossy();
    if let Some(rest) = value.strip_prefix(r"\\?\UNC\") {
        PathBuf::from(format!(r"\\{rest}"))
    } else if let Some(rest) = value.strip_prefix(r"\\?\") {
        PathBuf::from(rest)
    } else {
        path
    }
}

fn run_elevated(payload: String) -> Result<bool> {
    if !powershell::is_elevated()? {
        bail!("the system worker requires an administrator token");
    }
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload)
        .map_err(|error| anyhow::anyhow!("invalid elevated request: {error}"))?;
    let request: ElevatedRequest = serde_json::from_slice(&bytes)?;
    let mut events = EventEmitter::capture_only(&request.capture_path)
        .context("failed to open elevated output capture")?;
    let result = run_elevated_request(&request, &mut events).and_then(|result| {
        std::fs::write(&request.result_path, serde_json::to_vec(&result)?)
            .context("failed to return elevated execution result")?;
        Ok(match request.operation {
            WorkerOperation::Plan => engine::system_restart_pending(&result),
            WorkerOperation::Apply => engine::system_restart_required(&result),
        })
    });
    if let Err(error) = &result {
        events.emit(
            "operation_failed",
            json!({ "diagnostic": { "severity": "error", "code": "execution.elevated_worker.failed", "message": format!("{error:#}") } }),
        );
    }
    result
}

fn run_elevated_request(request: &ElevatedRequest, events: &mut EventEmitter) -> Result<Value> {
    let operation = match request.operation {
        WorkerOperation::Plan => "plan",
        WorkerOperation::Apply => "apply",
    };
    events.emit("operation_started", operation_payload(operation, None));
    let plugins = plugin::discover(&request.plugins_dir)?;
    let document = json!({ "version": 1, "system": request.system.clone() });
    engine::validate_document(&document, &plugins)?;
    let plan = if request.plan.is_null() {
        engine::plan(
            &document,
            &plugins,
            engine::Scope::System,
            &request.device,
            events,
        )?
    } else {
        request.plan.clone()
    };
    engine::validate_plan_sequence(&[&plan])?;
    let result = match request.operation {
        WorkerOperation::Plan => plan,
        WorkerOperation::Apply => engine::apply_plan(
            &document,
            &plugins,
            engine::Scope::System,
            &request.device,
            events,
            &plan,
        )?,
    };
    events.emit(
        "operation_completed",
        operation_payload(operation, Some(result.clone())),
    );
    Ok(result)
}

fn run_user(request_path: &std::path::Path) -> Result<bool> {
    let bytes = std::fs::read(request_path).context("failed to read current-user request")?;
    let request: UserRequest = serde_json::from_slice(&bytes)
        .map_err(|error| anyhow::anyhow!("invalid current-user request: {error}"))?;
    powershell::initialize(request.powershell.clone())?;
    if powershell::is_elevated()? {
        bail!("the current-user worker requires a non-elevated token");
    }
    let mut events = EventEmitter::capture_only(&request.capture_path)
        .context("failed to open current-user output capture")?;
    let result = run_user_request(&request, &mut events).and_then(|result| {
        std::fs::write(&request.result_path, serde_json::to_vec(&result)?)
            .context("failed to return current-user execution result")?;
        Ok(match request.operation {
            WorkerOperation::Plan => engine::system_restart_pending(&result),
            WorkerOperation::Apply => engine::system_restart_required(&result),
        })
    });
    if let Err(error) = &result {
        events.emit(
            "operation_failed",
            json!({ "diagnostic": { "severity": "error", "code": "execution.user_worker.failed", "message": format!("{error:#}") } }),
        );
    }
    let status = match &result {
        Ok(true) => powershell::REBOOT_REQUIRED_EXIT_CODE,
        Ok(false) => 0,
        Err(_) => 1,
    };
    std::fs::write(&request.status_path, status.to_string())
        .context("failed to return current-user worker status")?;
    result
}

fn run_user_request(request: &UserRequest, events: &mut EventEmitter) -> Result<Value> {
    let operation = match request.operation {
        WorkerOperation::Plan => "plan",
        WorkerOperation::Apply => "apply",
    };
    events.emit("operation_started", operation_payload(operation, None));
    let plugins = plugin::discover(&request.plugins_dir)?;
    let document = json!({ "version": 1, "users": { "current": request.user.clone() } });
    engine::validate_document(&document, &plugins)?;
    let plan = engine::plan_with_prior_operations(
        &document,
        &plugins,
        engine::Scope::UserCurrent,
        &request.device,
        events,
        &request.prior_operations,
    )?;
    if matches!(request.operation, WorkerOperation::Apply) {
        engine::validate_plan_sequence(&[&plan])?;
    }
    let result = match request.operation {
        WorkerOperation::Plan => plan,
        WorkerOperation::Apply => engine::apply_plan(
            &document,
            &plugins,
            engine::Scope::UserCurrent,
            &request.device,
            events,
            &plan,
        )?,
    };
    events.emit(
        "operation_completed",
        operation_payload(operation, Some(result.clone())),
    );
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_scope_is_user_only_when_unelevated() {
        assert_eq!(
            scope_steps(false, false, false, false),
            vec![ApplyStep::User]
        );
    }

    #[test]
    fn default_scope_is_all_when_elevated() {
        assert_eq!(
            scope_steps(false, false, false, true),
            vec![ApplyStep::System, ApplyStep::User]
        );
    }

    #[test]
    fn explicit_scopes_override_elevation_default() {
        assert_eq!(
            scope_steps(false, true, false, false),
            vec![ApplyStep::System]
        );
        assert_eq!(scope_steps(false, false, true, true), vec![ApplyStep::User]);
        assert_eq!(
            scope_steps(true, false, false, false),
            vec![ApplyStep::System, ApplyStep::User]
        );
    }

    #[test]
    fn plan_and_apply_scope_flags_are_mutually_exclusive() {
        assert!(Cli::try_parse_from(["winix-cfg", "plan", "--system", "--user"]).is_err());
        assert!(Cli::try_parse_from(["winix-cfg", "plan", "--all", "--user"]).is_err());
        assert!(Cli::try_parse_from(["winix-cfg", "apply", "--all", "--system"]).is_err());
    }

    #[test]
    fn removes_windows_extended_path_prefix_for_powershell() {
        assert_eq!(
            powershell_compatible_path(PathBuf::from(r"\\?\C:\src\winix\plugins")),
            PathBuf::from(r"C:\src\winix\plugins")
        );
        assert_eq!(
            powershell_compatible_path(PathBuf::from(r"\\?\UNC\server\share\plugins")),
            PathBuf::from(r"\\server\share\plugins")
        );
    }
}
