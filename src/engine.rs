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
        if !validate_validation_response(&plugin.manifest.name, &validation)? {
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
        return Ok(execution_result(
            "inspect",
            scope_name,
            device,
            Vec::new(),
            results,
        ));
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
        if !validate_plan_response(&plugin.manifest.name, &plan_response)? {
            let message = plugin_failure_message(&plan_response);
            bail!(
                "plugin {} could not apply configuration:\n{message}",
                plugin.manifest.name
            );
        }
        results.insert(task.absolute_path.clone(), plan_response);
    }

    for task in &tasks {
        let plugin = &plugins[task.plugin_index];
        let dependency_ids = required_operation_ids(task.plugin_index, plugins, &tasks, &results);
        let plan_response = results
            .get_mut(&task.absolute_path)
            .expect("planned result was inserted");
        add_operation_dependencies(plan_response, &dependency_ids)?;
        validate_operations(
            &plugin.manifest.name,
            plan_response["operations"]
                .as_array()
                .expect("operation array was validated after planning"),
        )?;
    }

    let result_order = tasks.into_iter().map(|task| task.absolute_path).collect();
    Ok(execution_result(
        "inspect",
        scope_name,
        device,
        result_order,
        results,
    ))
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
                    let result = match result {
                        Ok(response) => {
                            let accepted = match operation {
                                "validate" => {
                                    validate_validation_response(&plugin.manifest.name, &response)
                                }
                                "plan" => validate_plan_response(&plugin.manifest.name, &response),
                                _ => Ok(true),
                            };
                            match accepted {
                                Ok(false) => {
                                    let message = plugin_failure_message(&response);
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
                                    Ok(response)
                                }
                                Ok(true) => {
                                    events.emit_plugin(
                                        "plugin_completed",
                                        &plugin.manifest.name,
                                        &task.absolute_path,
                                        task.scope_name,
                                        device,
                                        json!({ "operation": operation, "result": response }),
                                    );
                                    Ok(response)
                                }
                                Err(error) => {
                                    events.emit_plugin(
                                        "plugin_failed",
                                        &plugin.manifest.name,
                                        &task.absolute_path,
                                        task.scope_name,
                                        device,
                                        json!({
                                            "operation": operation,
                                            "diagnostic": {
                                                "severity": "error",
                                                "code": "plugin.protocol.invalid_result",
                                                "message": format!("{error:#}")
                                            }
                                        }),
                                    );
                                    Err(error)
                                }
                            }
                        }
                        Err(error) => Err(error),
                    };
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
    plugin_index: usize,
    plugins: &[Plugin],
    tasks: &[PluginTask],
    results: &serde_json::Map<String, Value>,
) -> Vec<String> {
    let plugin = &plugins[plugin_index];
    let Some(fragment) = plugin.manifest.requires.configuration.as_ref() else {
        return Vec::new();
    };
    tasks
        .iter()
        .filter(|candidate_task| {
            candidate_task.plugin_index != plugin_index
                && plugin::configuration_at_path(
                    fragment,
                    &plugins[candidate_task.plugin_index].manifest.path,
                )
                .is_some()
        })
        .filter_map(|candidate_task| results.get(&candidate_task.absolute_path))
        .flat_map(|result| {
            result
                .get("operations")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
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
    let planned_result_order = ordered_result_paths(plan)?;
    let mut results = planned_results.clone();
    let Some(scope_root) = scope_root else {
        if planned_results.is_empty() {
            return Ok(execution_result(
                "apply",
                scope_name,
                device,
                Vec::new(),
                results,
            ));
        }
        bail!("the supplied plan contains operations for a missing configuration scope");
    };

    let mut prepared = Vec::new();
    let mut expected_paths = std::collections::HashSet::new();
    let mut expected_order = Vec::new();
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
        expected_order.push(absolute_path.clone());
        let plan_response = planned_results
            .get(&absolute_path)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("the supplied plan is missing {absolute_path}"))?;
        let operations = plan_response["operations"].as_array().ok_or_else(|| {
            anyhow::anyhow!("the supplied plan has no operations for {absolute_path}")
        })?;
        validate_operations(&plugin.manifest.name, operations)?;
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
    if !planned_result_order
        .iter()
        .copied()
        .eq(expected_order.iter().map(String::as_str))
    {
        bail!("the supplied plan plugin order does not match the current configuration");
    }
    apply_prepared(plugins, scope_name, device, events, prepared, &mut results)?;
    Ok(execution_result(
        "apply",
        scope_name,
        device,
        expected_order,
        results,
    ))
}

pub fn planned_operations(plan: &Value) -> Vec<Value> {
    planned_operations_checked(plan).unwrap_or_default()
}

fn planned_operations_checked(plan: &Value) -> Result<Vec<Value>> {
    Ok(ordered_plan_results(plan)?
        .into_iter()
        .filter_map(|result| result["operations"].as_array())
        .flatten()
        .cloned()
        .collect())
}

fn ordered_plan_results(plan: &Value) -> Result<Vec<&Value>> {
    if plan.is_null() {
        return Ok(Vec::new());
    }
    let results = plan["results"]
        .as_object()
        .ok_or_else(|| anyhow::anyhow!("the supplied plan has no plugin results"))?;
    let paths = ordered_result_paths(plan)?;
    Ok(paths
        .into_iter()
        .map(|path| {
            results
                .get(path)
                .expect("ordered result paths were validated against plan results")
        })
        .collect())
}

fn ordered_result_paths(plan: &Value) -> Result<Vec<&str>> {
    if plan.is_null() {
        return Ok(Vec::new());
    }
    let results = plan["results"]
        .as_object()
        .ok_or_else(|| anyhow::anyhow!("the supplied plan has no plugin results"))?;
    let Some(order) = plan.get("result_order") else {
        if results.is_empty() {
            return Ok(Vec::new());
        }
        bail!("the supplied plan has no result_order array");
    };
    let order = order
        .as_array()
        .ok_or_else(|| anyhow::anyhow!("the supplied plan has a non-array result_order"))?;
    if order.len() != results.len() {
        bail!("the supplied plan result_order does not cover every plugin result");
    }

    let mut seen = std::collections::HashSet::new();
    let mut paths = Vec::with_capacity(order.len());
    for path in order {
        let path = path.as_str().ok_or_else(|| {
            anyhow::anyhow!("the supplied plan has a non-string result_order path")
        })?;
        if !seen.insert(path) {
            bail!("the supplied plan repeats plugin path {path:?} in result_order");
        }
        if !results.contains_key(path) {
            bail!("the supplied plan result_order references missing plugin path {path:?}");
        }
        paths.push(path);
    }
    Ok(paths)
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
    let mut operations = Vec::new();
    for plan in plans {
        operations.extend(planned_operations_checked(plan)?);
    }
    for operation in operations {
        let id = operation["id"]
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("planned operation is missing a string id"))?;
        if seen.contains(id) {
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
        seen.insert(id.to_owned());
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
        if !validate_apply_response(&plugin.manifest.name, &response)? {
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

fn validate_validation_response(plugin_name: &str, response: &Value) -> Result<bool> {
    let response = response.as_object().ok_or_else(|| {
        anyhow::anyhow!("plugin {plugin_name} returned a non-object validation response")
    })?;
    let valid = response
        .get("valid")
        .and_then(Value::as_bool)
        .ok_or_else(|| {
            anyhow::anyhow!(
                "plugin {plugin_name} returned validation without a boolean valid field"
            )
        })?;
    require_array_field(plugin_name, "validation", response, "diagnostics")?;
    Ok(valid)
}

fn validate_plan_response(plugin_name: &str, response: &Value) -> Result<bool> {
    let response = response.as_object().ok_or_else(|| {
        anyhow::anyhow!("plugin {plugin_name} returned a non-object plan response")
    })?;
    let success = require_boolean_field(plugin_name, "plan", response, "success")?;
    if !success {
        return Ok(false);
    }
    if response.get("changed") != Some(&Value::Bool(false)) {
        bail!("plugin {plugin_name} returned a successful plan without changed=false");
    }
    let operations = require_array_field(plugin_name, "plan", response, "operations")?;
    validate_operations(plugin_name, operations)?;
    require_array_field(plugin_name, "plan", response, "diagnostics")?;
    validate_restart_required(plugin_name, "plan", response)?;
    Ok(true)
}

fn validate_apply_response(plugin_name: &str, response: &Value) -> Result<bool> {
    let response = response.as_object().ok_or_else(|| {
        anyhow::anyhow!("plugin {plugin_name} returned a non-object apply response")
    })?;
    let success = require_boolean_field(plugin_name, "apply", response, "success")?;
    if !success {
        return Ok(false);
    }
    require_boolean_field(plugin_name, "apply", response, "changed")?;
    let operations = require_array_field(plugin_name, "apply", response, "operations")?;
    validate_operations(plugin_name, operations)?;
    let applied = require_array_field(plugin_name, "apply", response, "applied_operation_ids")?;
    for (index, id) in applied.iter().enumerate() {
        require_nonempty_string(plugin_name, "apply", "applied operation ID", index, id)?;
    }
    require_array_field(plugin_name, "apply", response, "diagnostics")?;
    validate_restart_required(plugin_name, "apply", response)?;
    Ok(true)
}

fn require_boolean_field(
    plugin_name: &str,
    phase: &str,
    response: &serde_json::Map<String, Value>,
    field: &str,
) -> Result<bool> {
    response.get(field).and_then(Value::as_bool).ok_or_else(|| {
        anyhow::anyhow!("plugin {plugin_name} returned {phase} without a boolean {field} field")
    })
}

fn require_array_field<'a>(
    plugin_name: &str,
    phase: &str,
    response: &'a serde_json::Map<String, Value>,
    field: &str,
) -> Result<&'a Vec<Value>> {
    response
        .get(field)
        .and_then(Value::as_array)
        .ok_or_else(|| {
            anyhow::anyhow!("plugin {plugin_name} returned {phase} without an array {field} field")
        })
}

fn validate_restart_required(
    plugin_name: &str,
    phase: &str,
    response: &serde_json::Map<String, Value>,
) -> Result<()> {
    let restart = response
        .get("restart_required")
        .and_then(Value::as_object)
        .ok_or_else(|| {
            anyhow::anyhow!(
                "plugin {plugin_name} returned {phase} without an object restart_required field"
            )
        })?;
    require_boolean_field(plugin_name, phase, restart, "explorer")?;
    require_boolean_field(plugin_name, phase, restart, "system")?;
    Ok(())
}

fn validate_operations(plugin_name: &str, operations: &[Value]) -> Result<()> {
    for (index, operation) in operations.iter().enumerate() {
        let operation = operation.as_object().ok_or_else(|| {
            anyhow::anyhow!("plugin {plugin_name} returned non-object operation at index {index}")
        })?;
        let id = operation.get("id").ok_or_else(|| {
            anyhow::anyhow!("plugin {plugin_name} operation at index {index} is missing id")
        })?;
        require_nonempty_string(plugin_name, "operation", "id", index, id)?;
        let action = operation.get("action").ok_or_else(|| {
            anyhow::anyhow!("plugin {plugin_name} operation at index {index} is missing action")
        })?;
        require_nonempty_string(plugin_name, "operation", "action", index, action)?;

        let resource = operation
            .get("resource")
            .and_then(Value::as_object)
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "plugin {plugin_name} operation at index {index} has no resource object"
                )
            })?;
        for field in ["type", "id"] {
            let value = resource.get(field).ok_or_else(|| {
                anyhow::anyhow!(
                    "plugin {plugin_name} operation at index {index} resource is missing {field}"
                )
            })?;
            require_nonempty_string(plugin_name, "operation resource", field, index, value)?;
        }

        if !operation.contains_key("before") {
            bail!("plugin {plugin_name} operation at index {index} is missing before");
        }
        if !operation.contains_key("after") {
            bail!("plugin {plugin_name} operation at index {index} is missing after");
        }
        let data = operation
            .get("data")
            .and_then(Value::as_object)
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "plugin {plugin_name} operation at index {index} has no data object"
                )
            })?;
        if let Some(dependencies) = data.get("depends_on") {
            let dependencies = dependencies.as_array().ok_or_else(|| {
                anyhow::anyhow!(
                    "plugin {plugin_name} operation at index {index} has non-array depends_on"
                )
            })?;
            for (dependency_index, dependency) in dependencies.iter().enumerate() {
                require_nonempty_string(
                    plugin_name,
                    "operation dependency",
                    "depends_on",
                    dependency_index,
                    dependency,
                )?;
            }
        }
    }
    validate_operation_ids(plugin_name, operations)
}

fn require_nonempty_string(
    plugin_name: &str,
    phase: &str,
    field: &str,
    index: usize,
    value: &Value,
) -> Result<()> {
    if value.as_str().is_some_and(|value| !value.trim().is_empty()) {
        Ok(())
    } else {
        bail!("plugin {plugin_name} returned {phase} {index} without a nonempty string {field}")
    }
}

fn validate_operation_ids(plugin_name: &str, operations: &[Value]) -> Result<()> {
    let ids = operation_ids(operations);
    if ids.len() != operations.len() || ids.iter().any(|id| id.trim().is_empty()) {
        bail!("plugin {plugin_name} returned an operation without a nonempty string id");
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
    result_order: Vec<String>,
    results: serde_json::Map<String, Value>,
) -> Value {
    json!({
        "protocol_version": 1,
        "mode": mode,
        "scope": scope,
        "device": device.name,
        "device_overlay": device.overlay,
        "result_order": result_order,
        "results": results
    })
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;
    use std::path::PathBuf;

    use serde_json::{Value, json};

    use crate::plugin::{Manifest, PROTOCOL_VERSION, Requirements};

    use super::{
        Placement, Plugin, PluginTask, add_operation_dependencies, operation_ids,
        planned_operations, plugin_failure_message, required_operation_ids, system_restart_pending,
        system_restart_required, validate_apply_response, validate_operation_ids,
        validate_plan_response, validate_plan_sequence, validate_validation_response,
    };

    fn valid_operation() -> Value {
        json!({
            "id": "example.widget.install",
            "action": "install",
            "resource": {
                "type": "example.widget",
                "id": "Sample",
                "provider_extension": true
            },
            "before": null,
            "after": { "installed": true },
            "data": {
                "depends_on": [],
                "provider_extension": { "version": "1.2.3" }
            }
        })
    }

    fn valid_plan_response() -> Value {
        json!({
            "success": true,
            "changed": false,
            "state": { "provider_extension": true },
            "operations": [valid_operation()],
            "diagnostics": [],
            "restart_required": { "explorer": false, "system": false }
        })
    }

    fn valid_apply_response() -> Value {
        json!({
            "success": true,
            "changed": true,
            "state": { "provider_extension": true },
            "operations": [valid_operation()],
            "applied_operation_ids": ["example.widget.install"],
            "diagnostics": [],
            "restart_required": { "explorer": false, "system": false }
        })
    }

    fn mutate_json(value: &mut Value, pointer: &str, replacement: Option<Value>) {
        if let Some(replacement) = replacement {
            *value.pointer_mut(pointer).expect("test pointer exists") = replacement;
            return;
        }
        let (parent, field) = pointer.rsplit_once('/').expect("test pointer has a field");
        value
            .pointer_mut(parent)
            .and_then(Value::as_object_mut)
            .expect("test pointer parent is an object")
            .remove(field);
    }

    fn test_plugin(name: &str, path: &str, requirement: Option<Value>) -> Plugin {
        Plugin {
            directory: PathBuf::new(),
            manifest: Manifest {
                protocol_version: PROTOCOL_VERSION,
                name: name.into(),
                path: path.into(),
                placements: BTreeSet::from([Placement::User]),
                entrypoint: "plugin.ps1".into(),
                schema: "schema.json".into(),
                requires: Requirements {
                    configuration: requirement,
                    ..Requirements::default()
                },
            },
            schema: json!({ "type": "object" }),
        }
    }

    fn test_task(plugin_index: usize, absolute_path: &str) -> PluginTask {
        PluginTask {
            plugin_index,
            absolute_path: absolute_path.into(),
            scope_name: "user",
            request: Value::Null,
        }
    }

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
    fn validation_response_requires_boolean_valid_and_diagnostics_array() {
        assert!(
            validate_validation_response(
                "test",
                &json!({ "valid": true, "diagnostics": [], "extension": {} }),
            )
            .unwrap()
        );
        assert!(
            !validate_validation_response("test", &json!({ "valid": false, "diagnostics": [] }),)
                .unwrap()
        );
        assert!(validate_validation_response("test", &json!([])).is_err());

        let cases = vec![
            ("missing valid", "/valid", None),
            ("null valid", "/valid", Some(Value::Null)),
            ("string valid", "/valid", Some(json!("true"))),
            ("missing diagnostics", "/diagnostics", None),
            ("object diagnostics", "/diagnostics", Some(json!({}))),
        ];
        for (name, pointer, replacement) in cases {
            let mut response = json!({ "valid": true, "diagnostics": [] });
            mutate_json(&mut response, pointer, replacement);
            assert!(
                validate_validation_response("test", &response).is_err(),
                "accepted malformed validation response: {name}"
            );
        }
    }

    #[test]
    fn successful_plan_response_rejects_malformed_core_fields() {
        assert!(validate_plan_response("test", &valid_plan_response()).unwrap());
        assert!(!validate_plan_response("test", &json!({ "success": false })).unwrap());
        assert!(validate_plan_response("test", &json!([])).is_err());

        let duplicate = valid_operation();
        let cases = vec![
            ("missing success", "/success", None),
            ("null success", "/success", Some(Value::Null)),
            ("string success", "/success", Some(json!("true"))),
            ("missing changed", "/changed", None),
            ("changed true", "/changed", Some(json!(true))),
            ("null changed", "/changed", Some(Value::Null)),
            ("missing operations", "/operations", None),
            ("object operations", "/operations", Some(json!({}))),
            ("missing diagnostics", "/diagnostics", None),
            ("object diagnostics", "/diagnostics", Some(json!({}))),
            ("missing restart", "/restart_required", None),
            ("array restart", "/restart_required", Some(json!([]))),
            (
                "missing explorer restart",
                "/restart_required/explorer",
                None,
            ),
            (
                "string explorer restart",
                "/restart_required/explorer",
                Some(json!("false")),
            ),
            ("missing system restart", "/restart_required/system", None),
            (
                "numeric system restart",
                "/restart_required/system",
                Some(json!(0)),
            ),
            ("non-object operation", "/operations/0", Some(json!("bad"))),
            ("missing id", "/operations/0/id", None),
            ("empty id", "/operations/0/id", Some(json!(""))),
            ("blank id", "/operations/0/id", Some(json!("  "))),
            ("numeric id", "/operations/0/id", Some(json!(1))),
            ("missing action", "/operations/0/action", None),
            ("empty action", "/operations/0/action", Some(json!(""))),
            ("numeric action", "/operations/0/action", Some(json!(1))),
            ("missing resource", "/operations/0/resource", None),
            ("array resource", "/operations/0/resource", Some(json!([]))),
            ("missing resource type", "/operations/0/resource/type", None),
            (
                "empty resource type",
                "/operations/0/resource/type",
                Some(json!("")),
            ),
            ("missing resource id", "/operations/0/resource/id", None),
            (
                "numeric resource id",
                "/operations/0/resource/id",
                Some(json!(1)),
            ),
            ("missing before", "/operations/0/before", None),
            ("missing after", "/operations/0/after", None),
            ("missing data", "/operations/0/data", None),
            ("array data", "/operations/0/data", Some(json!([]))),
            (
                "null dependencies",
                "/operations/0/data/depends_on",
                Some(Value::Null),
            ),
            (
                "string dependencies",
                "/operations/0/data/depends_on",
                Some(json!("provider")),
            ),
            (
                "empty dependency",
                "/operations/0/data/depends_on",
                Some(json!([""])),
            ),
            (
                "numeric dependency",
                "/operations/0/data/depends_on",
                Some(json!([1])),
            ),
            (
                "duplicate operation id",
                "/operations",
                Some(json!([valid_operation(), duplicate])),
            ),
        ];
        for (name, pointer, replacement) in cases {
            let mut response = valid_plan_response();
            mutate_json(&mut response, pointer, replacement);
            assert!(
                validate_plan_response("test", &response).is_err(),
                "accepted malformed plan response: {name}"
            );
        }
    }

    #[test]
    fn successful_apply_response_rejects_malformed_core_fields() {
        assert!(validate_apply_response("test", &valid_apply_response()).unwrap());
        let mut unchanged = valid_apply_response();
        unchanged["changed"] = Value::Bool(false);
        assert!(validate_apply_response("test", &unchanged).unwrap());
        assert!(!validate_apply_response("test", &json!({ "success": false })).unwrap());
        assert!(validate_apply_response("test", &json!([])).is_err());

        let cases = vec![
            ("missing success", "/success", None),
            ("null success", "/success", Some(Value::Null)),
            ("string success", "/success", Some(json!("true"))),
            ("missing changed", "/changed", None),
            ("null changed", "/changed", Some(Value::Null)),
            ("string changed", "/changed", Some(json!("true"))),
            ("missing operations", "/operations", None),
            ("object operations", "/operations", Some(json!({}))),
            ("missing applied ids", "/applied_operation_ids", None),
            (
                "object applied ids",
                "/applied_operation_ids",
                Some(json!({})),
            ),
            (
                "empty applied id",
                "/applied_operation_ids",
                Some(json!([""])),
            ),
            (
                "numeric applied id",
                "/applied_operation_ids",
                Some(json!([1])),
            ),
            ("missing diagnostics", "/diagnostics", None),
            ("object diagnostics", "/diagnostics", Some(json!({}))),
            ("missing restart", "/restart_required", None),
            (
                "null system restart",
                "/restart_required/system",
                Some(Value::Null),
            ),
            ("operation missing data", "/operations/0/data", None),
        ];
        for (name, pointer, replacement) in cases {
            let mut response = valid_apply_response();
            mutate_json(&mut response, pointer, replacement);
            assert!(
                validate_apply_response("test", &response).is_err(),
                "accepted malformed apply response: {name}"
            );
        }
    }

    #[test]
    fn global_plan_dependencies_must_reference_earlier_unique_operations() {
        let first = json!({
            "result_order": ["a"],
            "results": { "a": { "operations": [{
                "id": "system.remove", "data": { "depends_on": [] }
            }] } }
        });
        let second = json!({
            "result_order": ["b"],
            "results": { "b": { "operations": [{
                "id": "user.install", "data": { "depends_on": ["system.remove"] }
            }] } }
        });
        assert!(validate_plan_sequence(&[&first, &second]).is_ok());

        let missing = json!({
            "result_order": ["b"],
            "results": { "b": { "operations": [{
                "id": "user.install", "data": { "depends_on": ["missing"] }
            }] } }
        });
        assert!(validate_plan_sequence(&[&missing]).is_err());
        assert!(validate_plan_sequence(&[&first, &first]).is_err());

        let self_dependency = json!({
            "result_order": ["self"],
            "results": { "self": { "operations": [{
                "id": "self.configure", "data": { "depends_on": ["self.configure"] }
            }] } }
        });
        assert!(validate_plan_sequence(&[&self_dependency]).is_err());
    }

    #[test]
    fn plan_sequence_uses_explicit_task_order_after_reordered_property_round_trip() {
        let plan = json!({
            "result_order": ["z.provider", "a.dependent"],
            "results": {
                "a.dependent": { "operations": [{
                    "id": "dependent.install",
                    "data": { "depends_on": ["provider.install"] }
                }] },
                "z.provider": { "operations": [{
                    "id": "provider.install",
                    "data": { "depends_on": [] }
                }] }
            }
        });
        let round_tripped: Value =
            serde_json::from_str(&serde_json::to_string(&plan).unwrap()).unwrap();

        assert_eq!(
            round_tripped["results"]
                .as_object()
                .unwrap()
                .keys()
                .map(String::as_str)
                .collect::<Vec<_>>(),
            vec!["a.dependent", "z.provider"]
        );
        assert_eq!(
            planned_operations(&round_tripped)
                .iter()
                .filter_map(|operation| operation["id"].as_str())
                .collect::<Vec<_>>(),
            vec!["provider.install", "dependent.install"]
        );
        assert!(validate_plan_sequence(&[&round_tripped]).is_ok());

        let mut reversed = round_tripped;
        reversed["result_order"] = json!(["a.dependent", "z.provider"]);
        assert!(validate_plan_sequence(&[&reversed]).is_err());
    }

    #[test]
    fn dependency_ids_use_exact_task_identity_despite_suffix_collision() {
        let plugins = vec![
            test_plugin("provider", "bar", None),
            test_plugin("suffix-collision", "foo.bar", None),
            test_plugin("dependent", "dependent", Some(json!({ "bar": {} }))),
        ];
        let tasks = vec![
            test_task(0, "users.current.bar"),
            test_task(1, "users.current.foo.bar"),
            test_task(2, "users.current.dependent"),
        ];
        let results = json!({
            "users.current.bar": {
                "operations": [{ "id": "provider.install" }]
            },
            "users.current.foo.bar": {
                "operations": [{ "id": "collision.install" }]
            },
            "users.current.dependent": {
                "operations": [{ "id": "dependent.install" }]
            }
        });

        assert_eq!(
            required_operation_ids(2, &plugins, &tasks, results.as_object().unwrap()),
            vec!["provider.install"]
        );
    }

    #[test]
    fn plugin_requirement_never_creates_a_self_dependency() {
        let plugins = vec![test_plugin(
            "self-requiring",
            "feature",
            Some(json!({ "feature": {} })),
        )];
        let tasks = vec![test_task(0, "users.current.feature")];
        let results = json!({
            "users.current.feature": {
                "operations": [{ "id": "feature.configure" }]
            }
        });

        assert!(
            required_operation_ids(0, &plugins, &tasks, results.as_object().unwrap()).is_empty()
        );
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
