use anyhow::{Result, bail};
use serde_json::{Value, json};

use crate::{device::DeviceContext, event::EventEmitter, plugin, powershell, schema};
use plugin::{Placement, Plugin};

#[derive(Debug, Clone, Copy)]
pub enum Scope {
    System,
    UserCurrent,
}

pub fn validate_document(document: &Value, plugins: &[Plugin]) -> Result<()> {
    let combined = schema::compose(plugins)?;
    let validator = jsonschema::JSONSchema::options()
        .with_draft(jsonschema::Draft::Draft202012)
        .compile(&combined)
        .map_err(|error| anyhow::anyhow!("generated schema is invalid: {error}"))?;
    let errors: Vec<String> = match validator.validate(document) {
        Ok(()) => Vec::new(),
        Err(errors) => errors
            .map(|error| {
                let path = if error.instance_path.to_string().is_empty() {
                    "/".to_owned()
                } else {
                    error.instance_path.to_string()
                };
                format!("{path}: {error}")
            })
            .collect(),
    };
    if !errors.is_empty() {
        bail!(
            "configuration validation failed:\n  - {}",
            errors.join("\n  - ")
        );
    }
    Ok(())
}

pub fn validate_plugins(
    document: &Value,
    plugins: &[Plugin],
    scopes: &[Scope],
    device: &DeviceContext,
    events: &mut EventEmitter,
) -> Result<()> {
    let elevated = powershell::is_elevated()?;
    let mut tasks = Vec::new();
    for &scope in scopes {
        let (scope_root, placement, scope_name, selector, path_prefix) = match scope {
            Scope::System => (
                document.get("system"),
                Placement::System,
                "system",
                Value::Null,
                "system",
            ),
            Scope::UserCurrent => (
                document.get("users").and_then(|users| users.get("current")),
                Placement::User,
                "user",
                Value::String("current".into()),
                "users.current",
            ),
        };
        let Some(scope_root) = scope_root else {
            continue;
        };
        for (plugin_index, plugin) in plugins.iter().enumerate() {
            if !plugin.supports(placement) {
                continue;
            }
            let Some(configuration) =
                plugin::configuration_at_path(scope_root, &plugin.manifest.path)
            else {
                continue;
            };
            let absolute_path = format!("{path_prefix}.{}", plugin.manifest.path);
            let request = json!({
                "protocol_version": plugin::PROTOCOL_VERSION,
                "plugin": plugin.manifest.name,
                "path": absolute_path,
                "configuration": configuration,
                "context": {
                    "scope": scope_name,
                    "user_selector": selector,
                    "device": device.name,
                    "device_overlay": device.overlay,
                    "user_sid": device.user_sid,
                    "elevated": elevated,
                    "dry_run": true
                }
            });
            tasks.push(PluginTask {
                plugin_index,
                absolute_path,
                scope_name,
                request,
            });
        }
    }

    let mut responses = invoke_plugin_tasks(plugins, "validate", &tasks, device, events)?;
    for (task_index, task) in tasks.iter().enumerate() {
        let plugin = &plugins[task.plugin_index];
        let validation = responses[task_index]
            .take()
            .expect("every validation worker returned a result")?;
        if validation.get("valid") != Some(&Value::Bool(true)) {
            bail!(
                "plugin {} rejected configuration at {}: {}",
                plugin.manifest.name,
                task.absolute_path,
                serde_json::to_string_pretty(&validation)?
            );
        }
    }
    Ok(())
}

pub fn plan(
    document: &Value,
    plugins: &[Plugin],
    scope: Scope,
    device: &DeviceContext,
    events: &mut EventEmitter,
) -> Result<Value> {
    plan_with_prior_operations(document, plugins, scope, device, events, &[])
}

pub fn plan_with_prior_operations(
    document: &Value,
    plugins: &[Plugin],
    scope: Scope,
    device: &DeviceContext,
    events: &mut EventEmitter,
    prior_operations: &[Value],
) -> Result<Value> {
    let (scope_root, placement, scope_name, selector) = match scope {
        Scope::System => (
            document.get("system"),
            Placement::System,
            "system",
            Value::Null,
        ),
        Scope::UserCurrent => (
            document.get("users").and_then(|users| users.get("current")),
            Placement::User,
            "user",
            Value::String("current".into()),
        ),
    };

    let mut results = serde_json::Map::new();
    let Some(scope_root) = scope_root else {
        return Ok(execution_result("inspect", scope_name, device, results));
    };
    let elevated = powershell::is_elevated()?;
    let mut tasks = Vec::new();
    for (plugin_index, plugin) in plugins.iter().enumerate() {
        if !plugin.supports(placement) {
            continue;
        }
        let Some(configuration) = plugin::configuration_at_path(scope_root, &plugin.manifest.path)
        else {
            continue;
        };
        let absolute_path = format!(
            "{}.{}",
            match scope {
                Scope::System => "system",
                Scope::UserCurrent => "users.current",
            },
            plugin.manifest.path
        );
        let request = json!({
            "protocol_version": plugin::PROTOCOL_VERSION,
            "plugin": plugin.manifest.name,
            "path": format!("{}.{}", match scope { Scope::System => "system", Scope::UserCurrent => "users.current" }, plugin.manifest.path),
            "configuration": configuration,
            "context": {
                "scope": scope_name,
                "user_selector": selector,
                "device": device.name,
                "device_overlay": device.overlay,
                "user_sid": device.user_sid,
                "elevated": elevated,
                "dry_run": true,
                "prior_operations": prior_operations
            }
        });
        tasks.push(PluginTask {
            plugin_index,
            absolute_path,
            scope_name,
            request,
        });
    }

    let mut responses = invoke_plugin_tasks(plugins, "plan", &tasks, device, events)?;

    for (task_index, task) in tasks.iter().enumerate() {
        let plugin = &plugins[task.plugin_index];
        let plan_response = responses[task_index]
            .take()
            .expect("every planning worker returned a result")?;
        if plan_response.get("success") == Some(&Value::Bool(false)) {
            let message = plugin_failure_message(&plan_response);
            bail!(
                "plugin {} could not apply configuration:\n{message}",
                plugin.manifest.name
            );
        }
        let operations = plan_response
            .get("operations")
            .and_then(Value::as_array)
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "plugin {} did not return an operations array during planning",
                    plugin.manifest.name
                )
            })?;
        validate_operation_ids(&plugin.manifest.name, operations)?;
        results.insert(task.absolute_path.clone(), plan_response);
    }

    for task in tasks {
        let plugin = &plugins[task.plugin_index];
        let dependency_ids = required_operation_ids(plugin, plugins, &results);
        let plan_response = results
            .get_mut(&task.absolute_path)
            .expect("planned result was inserted");
        add_operation_dependencies(plan_response, &dependency_ids)?;
        validate_operation_ids(
            &plugin.manifest.name,
            plan_response["operations"]
                .as_array()
                .expect("operation array was validated after planning"),
        )?;
    }

    Ok(execution_result("inspect", scope_name, device, results))
}

struct PluginTask {
    plugin_index: usize,
    absolute_path: String,
    scope_name: &'static str,
    request: Value,
}

enum PluginMessage {
    Event(usize, String, Value),
    Completed(usize, Result<Value>),
}

fn invoke_plugin_tasks(
    plugins: &[Plugin],
    operation: &'static str,
    tasks: &[PluginTask],
    device: &DeviceContext,
    events: &mut EventEmitter,
) -> Result<Vec<Option<Result<Value>>>> {
    for task in tasks {
        let plugin = &plugins[task.plugin_index];
        events.emit_plugin(
            "plugin_started",
            &plugin.manifest.name,
            &task.absolute_path,
            task.scope_name,
            device,
            json!({ "operation": operation }),
        );
    }

    std::thread::scope(|scope| -> Result<Vec<Option<Result<Value>>>> {
        let (sender, receiver) = std::sync::mpsc::channel();
        for (task_index, task) in tasks.iter().enumerate() {
            let sender = sender.clone();
            let plugin = &plugins[task.plugin_index];
            scope.spawn(move || {
                let event_sender = sender.clone();
                let result = powershell::invoke_with_events(
                    plugin,
                    operation,
                    &task.request,
                    move |kind, payload| {
                        let _ = event_sender.send(PluginMessage::Event(
                            task_index,
                            kind.to_owned(),
                            payload,
                        ));
                    },
                );
                let _ = sender.send(PluginMessage::Completed(task_index, result));
            });
        }
        drop(sender);

        let mut responses = (0..tasks.len()).map(|_| None).collect::<Vec<_>>();
        let mut remaining = tasks.len();
        while remaining > 0 {
            match receiver.recv() {
                Ok(PluginMessage::Event(task_index, kind, payload)) => {
                    let task = &tasks[task_index];
                    let plugin = &plugins[task.plugin_index];
                    events.emit_plugin(
                        &kind,
                        &plugin.manifest.name,
                        &task.absolute_path,
                        task.scope_name,
                        device,
                        payload,
                    );
                }
                Ok(PluginMessage::Completed(task_index, result)) => {
                    let task = &tasks[task_index];
                    let plugin = &plugins[task.plugin_index];
                    if let Ok(response) = &result {
                        if operation == "plan"
                            && response.get("success") == Some(&Value::Bool(false))
                        {
                            let message = plugin_failure_message(response);
                            events.emit_plugin(
                                "plugin_failed",
                                &plugin.manifest.name,
                                &task.absolute_path,
                                task.scope_name,
                                device,
                                json!({
                                    "operation": operation,
                                    "diagnostic": {
                                        "code": response["error"]["code"],
                                        "message": message
                                    }
                                }),
                            );
                        } else {
                            events.emit_plugin(
                                "plugin_completed",
                                &plugin.manifest.name,
                                &task.absolute_path,
                                task.scope_name,
                                device,
                                json!({ "operation": operation, "result": response }),
                            );
                        }
                    }
                    responses[task_index] = Some(result);
                    remaining -= 1;
                }
                Err(_) => bail!("a plugin {operation} worker terminated without a result"),
            }
        }
        Ok(responses)
    })
}

fn required_operation_ids(
    plugin: &Plugin,
    plugins: &[Plugin],
    results: &serde_json::Map<String, Value>,
) -> Vec<String> {
    let Some(fragment) = plugin.manifest.requires.configuration.as_ref() else {
        return Vec::new();
    };
    plugins
        .iter()
        .filter(|candidate| {
            plugin::configuration_at_path(fragment, &candidate.manifest.path).is_some()
        })
        .flat_map(|candidate| {
            results
                .iter()
                .filter(move |(path, _)| path.ends_with(&format!(".{}", candidate.manifest.path)))
                .flat_map(|(_, result)| result["operations"].as_array().into_iter().flatten())
        })
        .filter_map(|operation| operation["id"].as_str().map(str::to_owned))
        .collect()
}

fn add_operation_dependencies(plan: &mut Value, dependencies: &[String]) -> Result<()> {
    if dependencies.is_empty() {
        return Ok(());
    }
    let operations = plan["operations"]
        .as_array_mut()
        .ok_or_else(|| anyhow::anyhow!("plugin plan is missing its operations array"))?;
    for operation in operations {
        let data = operation
            .get_mut("data")
            .and_then(Value::as_object_mut)
            .ok_or_else(|| anyhow::anyhow!("planned operation is missing its data object"))?;
        let depends_on = data
            .entry("depends_on")
            .or_insert_with(|| Value::Array(Vec::new()))
            .as_array_mut()
            .ok_or_else(|| anyhow::anyhow!("planned operation has a non-array depends_on value"))?;
        for dependency in dependencies {
            if !depends_on
                .iter()
                .any(|value| value.as_str() == Some(dependency))
            {
                depends_on.push(Value::String(dependency.clone()));
            }
        }
    }
    Ok(())
}

pub fn apply_plan(
    document: &Value,
    plugins: &[Plugin],
    scope: Scope,
    device: &DeviceContext,
    events: &mut EventEmitter,
    plan: &Value,
) -> Result<Value> {
    let (scope_root, placement, scope_name, selector) = match scope {
        Scope::System => (
            document.get("system"),
            Placement::System,
            "system",
            Value::Null,
        ),
        Scope::UserCurrent => (
            document.get("users").and_then(|users| users.get("current")),
            Placement::User,
            "user",
            Value::String("current".into()),
        ),
    };
    if plan["mode"] != "inspect"
        || plan["scope"] != scope_name
        || plan["device"] != device.name
        || plan["device_overlay"] != json!(&device.overlay)
    {
        bail!("the supplied plan does not match the current execution context");
    }
    let planned_results = plan["results"]
        .as_object()
        .ok_or_else(|| anyhow::anyhow!("the supplied plan has no plugin results"))?;
    let mut results = planned_results.clone();
    let Some(scope_root) = scope_root else {
        if planned_results.is_empty() {
            return Ok(execution_result("apply", scope_name, device, results));
        }
        bail!("the supplied plan contains operations for a missing configuration scope");
    };

    let mut prepared = Vec::new();
    let mut expected_paths = std::collections::HashSet::new();
    for (plugin_index, plugin) in plugins.iter().enumerate() {
        if !plugin.supports(placement) {
            continue;
        }
        let Some(configuration) = plugin::configuration_at_path(scope_root, &plugin.manifest.path)
        else {
            continue;
        };
        let absolute_path = format!(
            "{}.{}",
            match scope {
                Scope::System => "system",
                Scope::UserCurrent => "users.current",
            },
            plugin.manifest.path
        );
        expected_paths.insert(absolute_path.clone());
        let plan_response = planned_results
            .get(&absolute_path)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("the supplied plan is missing {absolute_path}"))?;
        let operations = plan_response["operations"].as_array().ok_or_else(|| {
            anyhow::anyhow!("the supplied plan has no operations for {absolute_path}")
        })?;
        validate_operation_ids(&plugin.manifest.name, operations)?;
        let request = json!({
            "protocol_version": plugin::PROTOCOL_VERSION,
            "plugin": plugin.manifest.name,
            "path": absolute_path,
            "configuration": configuration,
            "context": {
                "scope": scope_name,
                "user_selector": selector,
                "device": device.name,
                "device_overlay": device.overlay,
                "user_sid": device.user_sid,
                "elevated": powershell::is_elevated()?,
                "dry_run": false
            }
        });
        prepared.push((plugin_index, absolute_path, request, plan_response));
    }
    if planned_results
        .keys()
        .any(|path| !expected_paths.contains(path))
    {
        bail!("the supplied plan contains a plugin path not present in configuration");
    }
    apply_prepared(plugins, scope_name, device, events, prepared, &mut results)?;
    Ok(execution_result("apply", scope_name, device, results))
}

pub fn planned_operations(plan: &Value) -> Vec<Value> {
    plan["results"]
        .as_object()
        .into_iter()
        .flat_map(|results| results.values())
        .filter_map(|result| result["operations"].as_array())
        .flatten()
        .cloned()
        .collect()
}

pub fn system_restart_required(result: &Value) -> bool {
    match result {
        Value::Array(values) => values.iter().any(system_restart_required),
        Value::Object(object) => {
            object
                .get("restart_required")
                .and_then(Value::as_object)
                .and_then(|restart| restart.get("system"))
                .and_then(Value::as_bool)
                .unwrap_or(false)
                || object.values().any(system_restart_required)
        }
        _ => false,
    }
}

pub fn system_restart_pending(result: &Value) -> bool {
    match result {
        Value::Array(values) => values.iter().any(system_restart_pending),
        Value::Object(object) => {
            object
                .get("restart_pending")
                .and_then(Value::as_bool)
                .unwrap_or(false)
                || object.values().any(system_restart_pending)
        }
        _ => false,
    }
}

pub fn validate_plan_sequence(plans: &[&Value]) -> Result<()> {
    let mut seen = std::collections::HashSet::new();
    for operation in plans
        .iter()
        .flat_map(|plan| planned_operations(plan).into_iter())
    {
        let id = operation["id"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("planned operation is missing a string id"))?;
        if !seen.insert(id.to_owned()) {
            bail!("planned operation ID {id:?} is not globally unique");
        }
        if let Some(dependencies) = operation["data"]["depends_on"].as_array() {
            for dependency in dependencies {
                let dependency = dependency.as_str().ok_or_else(|| {
                    anyhow::anyhow!("operation {id:?} has a non-string prerequisite")
                })?;
                if !seen.contains(dependency) {
                    bail!(
                        "operation {id:?} depends on {dependency:?}, which is missing or ordered later"
                    );
                }
            }
        }
    }
    Ok(())
}

type PreparedPlugin = (usize, String, Value, Value);

fn apply_prepared(
    plugins: &[Plugin],
    scope_name: &str,
    device: &DeviceContext,
    events: &mut EventEmitter,
    prepared: Vec<PreparedPlugin>,
    results: &mut serde_json::Map<String, Value>,
) -> Result<()> {
    for (plugin_index, absolute_path, mut apply_request, plan_response) in prepared {
        let plugin = &plugins[plugin_index];
        let operations = plan_response["operations"]
            .as_array()
            .expect("operation array was validated during planning");
        if operations.is_empty() {
            continue;
        }
        let planned_operations = Value::Array(operations.clone());
        let planned_ids = operation_ids(operations);
        apply_request["context"]["dry_run"] = Value::Bool(false);
        apply_request["operations"] = planned_operations.clone();
        events.emit_plugin(
            "plugin_started",
            &plugin.manifest.name,
            &absolute_path,
            scope_name,
            device,
            json!({ "operation": "apply", "planned_operation_ids": planned_ids }),
        );
        let response = powershell::invoke(
            plugin,
            "apply",
            &apply_request,
            events,
            &absolute_path,
            scope_name,
            device,
        )?;
        if response.get("success") == Some(&Value::Bool(false)) {
            let message = plugin_failure_message(&response);
            events.emit_plugin(
                "plugin_failed",
                &plugin.manifest.name,
                &absolute_path,
                scope_name,
                device,
                json!({
                    "operation": "apply",
                    "diagnostic": {
                        "code": response["error"]["code"],
                        "message": &message
                    }
                }),
            );
            bail!(
                "plugin {} could not apply configuration:\n{message}",
                plugin.manifest.name
            );
        }
        if response.get("operations") != Some(&planned_operations) {
            bail!(
                "plugin {} returned an operation queue that differs from the approved plan",
                plugin.manifest.name
            );
        }
        let applied = response
            .get("applied_operation_ids")
            .and_then(Value::as_array)
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "plugin {} did not account for its applied operation IDs",
                    plugin.manifest.name
                )
            })?;
        let applied_ids = applied
            .iter()
            .map(|value| value.as_str().map(str::to_owned))
            .collect::<Option<Vec<_>>>()
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "plugin {} returned a non-string applied operation ID",
                    plugin.manifest.name
                )
            })?;
        if applied_ids != planned_ids {
            bail!(
                "plugin {} applied operations that differ from its plan: planned {:?}, applied {:?}",
                plugin.manifest.name,
                planned_ids,
                applied_ids
            );
        }
        events.emit_plugin(
            "plugin_completed",
            &plugin.manifest.name,
            &absolute_path,
            scope_name,
            device,
            json!({ "operation": "apply", "result": response }),
        );
        results.insert(absolute_path, response);
    }
    Ok(())
}

fn validate_operation_ids(plugin_name: &str, operations: &[Value]) -> Result<()> {
    let ids = operation_ids(operations);
    if ids.len() != operations.len() {
        bail!("plugin {plugin_name} returned an operation without a string id");
    }
    let unique = ids.iter().collect::<std::collections::HashSet<_>>();
    if unique.len() != ids.len() {
        bail!("plugin {plugin_name} returned duplicate operation IDs");
    }
    Ok(())
}

fn operation_ids(operations: &[Value]) -> Vec<String> {
    operations
        .iter()
        .filter_map(|operation| operation.get("id")?.as_str().map(str::to_owned))
        .collect()
}

fn plugin_failure_message(response: &Value) -> String {
    let summary = response["error"]["message"]
        .as_str()
        .unwrap_or("plugin rejected the operation");
    let mut lines = vec![summary.to_owned()];

    if let Some(diagnostics) = response["diagnostics"].as_array() {
        for diagnostic in diagnostics {
            let Some(message) = diagnostic["message"].as_str() else {
                continue;
            };
            lines.push(format!("- {message}"));
            if let Some(path) = diagnostic["path"].as_str() {
                lines.push(format!("  config: {path}"));
            }
            if let Some(help) = diagnostic["help"].as_str() {
                lines.push(format!("  help: {help}"));
            }
        }
    }

    lines.join("\n")
}

fn execution_result(
    mode: &str,
    scope: &str,
    device: &DeviceContext,
    results: serde_json::Map<String, Value>,
) -> Value {
    json!({
        "protocol_version": 1,
        "mode": mode,
        "scope": scope,
        "device": device.name,
        "device_overlay": device.overlay,
        "results": results
    })
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{
        add_operation_dependencies, operation_ids, plugin_failure_message, system_restart_pending,
        system_restart_required, validate_operation_ids, validate_plan_sequence,
    };

    #[test]
    fn plugin_failure_includes_diagnostic_path_and_help() {
        let response = json!({
            "success": false,
            "error": { "message": "Preflight failed." },
            "diagnostics": [{
                "message": "Git is installed at machine scope.",
                "path": "users.current.packages.winget.Git.Git",
                "help": "Move Git to system.packages.winget."
            }]
        });

        assert_eq!(
            plugin_failure_message(&response),
            "Preflight failed.\n- Git is installed at machine scope.\n  config: users.current.packages.winget.Git.Git\n  help: Move Git to system.packages.winget."
        );
    }

    #[test]
    fn planned_operation_ids_must_be_present_and_unique() {
        let valid = vec![json!({ "id": "one" }), json!({ "id": "two" })];
        assert!(validate_operation_ids("test", &valid).is_ok());
        assert_eq!(operation_ids(&valid), vec!["one", "two"]);

        assert!(validate_operation_ids("test", &[json!({ "action": "change" })]).is_err());
        assert!(
            validate_operation_ids("test", &[json!({ "id": "same" }), json!({ "id": "same" })])
                .is_err()
        );
    }

    #[test]
    fn global_plan_dependencies_must_reference_earlier_unique_operations() {
        let first = json!({ "results": { "a": { "operations": [{
            "id": "system.remove", "data": { "depends_on": [] }
        }] } } });
        let second = json!({ "results": { "b": { "operations": [{
            "id": "user.install", "data": { "depends_on": ["system.remove"] }
        }] } } });
        assert!(validate_plan_sequence(&[&first, &second]).is_ok());

        let missing = json!({ "results": { "b": { "operations": [{
            "id": "user.install", "data": { "depends_on": ["missing"] }
        }] } } });
        assert!(validate_plan_sequence(&[&missing]).is_err());
        assert!(validate_plan_sequence(&[&first, &first]).is_err());
    }

    #[test]
    fn provider_dependencies_are_attached_after_plans_are_collected() {
        let mut plan = json!({ "operations": [{
            "id": "dependent.install",
            "data": { "depends_on": ["existing.operation"] }
        }] });

        add_operation_dependencies(
            &mut plan,
            &["provider.install".into(), "existing.operation".into()],
        )
        .unwrap();

        assert_eq!(
            plan["operations"][0]["data"]["depends_on"],
            json!(["existing.operation", "provider.install"])
        );
    }

    #[test]
    fn distinguishes_pending_reboot_from_future_restart_requirement() {
        let future_restart = json!({
            "results": { "plugin": {
                "state": { "restart_pending": false },
                "restart_required": { "system": true, "explorer": false }
            }}
        });
        assert!(system_restart_required(&future_restart));
        assert!(!system_restart_pending(&future_restart));

        let pending_restart = json!({
            "results": { "plugin": {
                "state": { "restart_pending": true },
                "restart_required": { "system": true, "explorer": false }
            }}
        });
        assert!(system_restart_required(&pending_restart));
        assert!(system_restart_pending(&pending_restart));
    }
}
