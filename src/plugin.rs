use std::collections::{BTreeSet, HashSet};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use serde_json::Value;

pub const PROTOCOL_VERSION: u32 = 2;

#[derive(Debug, Clone, Deserialize)]
pub struct Manifest {
    pub protocol_version: u32,
    pub name: String,
    pub path: String,
    pub placements: BTreeSet<Placement>,
    pub entrypoint: PathBuf,
    pub schema: PathBuf,
    #[serde(default)]
    pub requires: Requirements,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Placement {
    System,
    User,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Requirements {
    pub powershell: Option<String>,
    #[serde(default)]
    pub administrator: bool,
    #[serde(default)]
    pub commands: Vec<String>,
    #[serde(default)]
    pub configuration: Option<Value>,
}

#[derive(Debug, Clone)]
pub struct Plugin {
    pub directory: PathBuf,
    pub manifest: Manifest,
    pub schema: Value,
}

pub fn discover(root: &Path) -> Result<Vec<Plugin>> {
    if !root.is_dir() {
        bail!("plugin directory does not exist: {}", root.display());
    }

    let mut manifests = Vec::new();
    find_manifests(root, &mut manifests)?;
    manifests.sort();

    let mut plugins = Vec::new();
    let mut paths = BTreeSet::new();
    for manifest_path in manifests {
        let directory = manifest_path
            .parent()
            .expect("manifest has parent")
            .to_path_buf();
        let text = std::fs::read_to_string(&manifest_path)?;
        let manifest: Manifest = serde_json::from_str(&text)
            .with_context(|| format!("invalid manifest {}", manifest_path.display()))?;
        validate_manifest(&manifest, &manifest_path)?;
        for placement in &manifest.placements {
            if !paths.insert((*placement, manifest.path.clone())) {
                bail!("duplicate plugin path for {placement:?}: {}", manifest.path);
            }
        }
        let schema_path = directory.join(&manifest.schema);
        let schema_text = std::fs::read_to_string(&schema_path)
            .with_context(|| format!("failed to read schema {}", schema_path.display()))?;
        let schema = serde_json::from_str(&schema_text)
            .with_context(|| format!("invalid JSON schema {}", schema_path.display()))?;
        let entrypoint = directory.join(&manifest.entrypoint);
        if !entrypoint.is_file() {
            bail!("plugin entrypoint does not exist: {}", entrypoint.display());
        }
        plugins.push(Plugin {
            directory,
            manifest,
            schema,
        });
    }

    reject_overlapping_paths(&plugins)?;
    order_by_configuration_requirements(&mut plugins)?;
    Ok(plugins)
}

fn order_by_configuration_requirements(plugins: &mut Vec<Plugin>) -> Result<()> {
    let mut ordered = Vec::with_capacity(plugins.len());
    let mut remaining = std::mem::take(plugins);
    let mut emitted = HashSet::new();

    while !remaining.is_empty() {
        let Some(index) = remaining.iter().position(|plugin| {
            required_plugin_names(plugin, &remaining, &ordered)
                .iter()
                .all(|name| emitted.contains(name))
        }) else {
            let names = remaining
                .iter()
                .map(|plugin| plugin.manifest.name.as_str())
                .collect::<Vec<_>>()
                .join(", ");
            bail!("plugin configuration requirements contain a cycle: {names}");
        };
        let plugin = remaining.remove(index);
        emitted.insert(plugin.manifest.name.clone());
        ordered.push(plugin);
    }

    *plugins = ordered;
    Ok(())
}

fn required_plugin_names(plugin: &Plugin, remaining: &[Plugin], ordered: &[Plugin]) -> Vec<String> {
    let Some(fragment) = plugin.manifest.requires.configuration.as_ref() else {
        return Vec::new();
    };
    remaining
        .iter()
        .chain(ordered.iter())
        .filter(|candidate| {
            candidate.manifest.name != plugin.manifest.name
                && configuration_at_path(fragment, &candidate.manifest.path).is_some()
        })
        .map(|candidate| candidate.manifest.name.clone())
        .collect()
}

pub fn with_required_configuration(document: &Value, plugins: &[Plugin]) -> Result<Value> {
    let mut effective = document.clone();
    loop {
        let mut additions = Vec::new();
        for (scope_path, placement) in [
            (vec!["system"], Placement::System),
            (vec!["users", "current"], Placement::User),
        ] {
            let Some(scope) = value_at_segments(&effective, &scope_path) else {
                continue;
            };
            for plugin in plugins {
                if plugin.supports(placement)
                    && configuration_at_path(scope, &plugin.manifest.path).is_some()
                    && let Some(fragment) = &plugin.manifest.requires.configuration
                {
                    additions.push((
                        scope_path.clone(),
                        plugin.manifest.name.clone(),
                        fragment.clone(),
                    ));
                }
            }
        }
        if additions.is_empty() {
            break;
        }

        let mut changed = false;
        for (scope_path, owner, fragment) in additions {
            let scope = value_at_segments_mut(&mut effective, &scope_path)
                .expect("configured plugin scope exists");
            changed |= merge_requirement(scope, &fragment, &scope_path.join("."), &owner)?;
        }
        if !changed {
            break;
        }
    }
    Ok(effective)
}

fn merge_requirement(
    target: &mut Value,
    required: &Value,
    path: &str,
    owner: &str,
) -> Result<bool> {
    match (target, required) {
        (Value::Object(target), Value::Object(required)) => {
            let mut changed = false;
            for (key, required_value) in required {
                let child_path = format!("{path}.{key}");
                if let Some(existing) = target.get_mut(key) {
                    changed |= merge_requirement(existing, required_value, &child_path, owner)?;
                } else {
                    target.insert(key.clone(), required_value.clone());
                    changed = true;
                }
            }
            Ok(changed)
        }
        (target, required) if target == required => Ok(false),
        (target, required) => bail!(
            "configuration at {path} conflicts with requirement from plugin {owner}: configured {}, required {}",
            serde_json::to_string(target)?,
            serde_json::to_string(required)?
        ),
    }
}

fn value_at_segments<'a>(value: &'a Value, segments: &[&str]) -> Option<&'a Value> {
    segments
        .iter()
        .try_fold(value, |current, segment| current.get(segment))
}

fn value_at_segments_mut<'a>(mut value: &'a mut Value, segments: &[&str]) -> Option<&'a mut Value> {
    for segment in segments {
        value = value.get_mut(*segment)?;
    }
    Some(value)
}

fn find_manifests(directory: &Path, output: &mut Vec<PathBuf>) -> Result<()> {
    for entry in std::fs::read_dir(directory)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            find_manifests(&path, output)?;
        } else if entry.file_name() == "plugin.json" {
            output.push(path);
        }
    }
    Ok(())
}

fn validate_manifest(manifest: &Manifest, path: &Path) -> Result<()> {
    if manifest.protocol_version != PROTOCOL_VERSION {
        bail!(
            "{} uses unsupported protocol version {}",
            path.display(),
            manifest.protocol_version
        );
    }
    if manifest.name.trim().is_empty() {
        bail!("{} has an empty plugin name", path.display());
    }
    if manifest.placements.is_empty() {
        bail!("{} does not declare any placements", path.display());
    }
    let segments: Vec<_> = manifest.path.split('.').collect();
    if segments.is_empty()
        || segments.iter().any(|segment| {
            segment.is_empty()
                || !segment
                    .chars()
                    .all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '_')
        })
    {
        bail!(
            "{} has invalid plugin path {:?}",
            path.display(),
            manifest.path
        );
    }
    Ok(())
}

fn reject_overlapping_paths(plugins: &[Plugin]) -> Result<()> {
    for (index, left) in plugins.iter().enumerate() {
        for right in &plugins[index + 1..] {
            let left_prefix = format!("{}.", left.manifest.path);
            let right_prefix = format!("{}.", right.manifest.path);
            let shares_placement = left
                .manifest
                .placements
                .iter()
                .any(|placement| right.manifest.placements.contains(placement));
            if shares_placement
                && (right.manifest.path.starts_with(&left_prefix)
                    || left.manifest.path.starts_with(&right_prefix))
            {
                bail!(
                    "plugin paths overlap: {} and {}",
                    left.manifest.path,
                    right.manifest.path
                );
            }
        }
    }
    Ok(())
}

impl Plugin {
    pub fn supports(&self, placement: Placement) -> bool {
        self.manifest.placements.contains(&placement)
    }
}

pub fn configuration_at_path<'a>(document: &'a Value, path: &str) -> Option<&'a Value> {
    path.split('.')
        .try_fold(document, |value, segment| value.get(segment))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[cfg(windows)]
    use std::io::Write;
    #[cfg(windows)]
    use std::process::{Command, Stdio};

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

    fn visit_schema_defaults(schema: &Value, visit: &mut impl FnMut(&Value)) {
        match schema {
            Value::Object(object) => {
                if object.contains_key("default") {
                    visit(schema);
                }
                for value in object.values() {
                    visit_schema_defaults(value, visit);
                }
            }
            Value::Array(values) => {
                for value in values {
                    visit_schema_defaults(value, visit);
                }
            }
            _ => {}
        }
    }

    #[cfg(windows)]
    fn run_plugin(
        plugin: &Plugin,
        operation: &str,
        request: &Value,
        environment: &[(&str, &std::ffi::OsStr)],
    ) -> Value {
        let mut command = Command::new(crate::powershell::ensure_available().unwrap());
        command
            .args([
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
            ])
            .arg(plugin.directory.join(&plugin.manifest.entrypoint))
            .args(["-Operation", operation])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        for (name, value) in environment {
            command.env(name, value);
        }

        let mut child = command.spawn().unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(&serde_json::to_vec(request).unwrap())
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "plugin failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout)
            .unwrap()
            .lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .find(|record| record["type"] == "result")
            .and_then(|record| record.get("result").cloned())
            .expect("plugin did not emit a result record")
    }

    #[test]
    fn injects_required_configuration_into_the_dependent_scope() {
        let dependency = test_plugin("modules", "packages.modules", None);
        let dependent = test_plugin(
            "winget",
            "packages.winget",
            Some(json!({ "packages": { "modules": { "Api.Client": { "state": "installed" } } } })),
        );
        let document = json!({
            "version": 1,
            "users": { "current": { "packages": { "winget": { "Example.App": {} } } } }
        });

        let effective = with_required_configuration(&document, &[dependency, dependent]).unwrap();
        assert_eq!(
            effective["users"]["current"]["packages"]["modules"]["Api.Client"]["state"],
            "installed"
        );
        assert!(effective.get("system").is_none());
    }

    #[test]
    fn explicit_configuration_cannot_disable_a_plugin_requirement() {
        let dependent = test_plugin(
            "winget",
            "packages.winget",
            Some(json!({ "packages": { "modules": { "Api.Client": { "state": "installed" } } } })),
        );
        let document = json!({
            "version": 1,
            "users": { "current": { "packages": {
                "winget": { "Example.App": {} },
                "modules": { "Api.Client": { "state": "absent" } }
            } } }
        });

        let error = with_required_configuration(&document, &[dependent]).unwrap_err();
        assert!(error.to_string().contains("conflicts with requirement"));
    }

    #[test]
    fn orders_configuration_provider_before_dependent_plugin() {
        let dependency = test_plugin("modules", "packages.modules", None);
        let dependent = test_plugin(
            "winget",
            "packages.winget",
            Some(json!({ "packages": { "modules": {} } })),
        );
        let mut plugins = vec![dependent, dependency];

        order_by_configuration_requirements(&mut plugins).unwrap();
        assert_eq!(plugins[0].manifest.name, "modules");
        assert_eq!(plugins[1].manifest.name, "winget");
    }

    #[test]
    fn closed_optional_plugin_objects_reject_empty_configuration() {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("plugins");
        for plugin in discover(&root).unwrap() {
            let schema = plugin.schema.as_object().unwrap();
            let is_closed = schema.get("additionalProperties") == Some(&Value::Bool(false));
            let has_optional_properties = schema
                .get("properties")
                .and_then(Value::as_object)
                .is_some_and(|properties| !properties.is_empty())
                && schema.get("required").is_none();
            if is_closed && has_optional_properties {
                assert_eq!(
                    schema.get("minProperties").and_then(Value::as_u64),
                    Some(1),
                    "{} must reject an empty configured object",
                    plugin.manifest.name
                );
            }
        }
    }

    #[test]
    fn schema_defaults_document_their_omission_semantics() {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("plugins");
        for plugin in discover(&root).unwrap() {
            visit_schema_defaults(&plugin.schema, &mut |schema| {
                let description = schema["description"]
                    .as_str()
                    .unwrap_or_default()
                    .to_ascii_lowercase();
                assert!(
                    description.contains("omit") || description.contains("omission"),
                    "default in {} must document what omission means",
                    plugin.manifest.name
                );
            });
        }
    }

    #[cfg(windows)]
    #[test]
    fn terminal_does_not_materialize_unconfigured_profile_structures() {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("plugins");
        let plugins = discover(&root).unwrap();
        let plugin = plugins
            .iter()
            .find(|plugin| plugin.manifest.name == "applications-windows-terminal")
            .unwrap();
        let temporary = tempfile::tempdir().unwrap();
        let settings = temporary
            .path()
            .join("Packages")
            .join("Microsoft.WindowsTerminal_8wekyb3d8bbwe")
            .join("LocalState")
            .join("settings.json");
        std::fs::create_dir_all(settings.parent().unwrap()).unwrap();
        std::fs::write(&settings, "{\"theme\":\"system\"}\n").unwrap();
        let request = json!({
            "protocol_version": 2,
            "plugin": plugin.manifest.name,
            "path": "users.current.applications.windows_terminal",
            "configuration": { "graphics_api": "automatic" },
            "context": {
                "scope": "user",
                "user_selector": "current",
                "device": "test",
                "device_overlay": null,
                "user_sid": null,
                "elevated": false
            }
        });

        let result = run_plugin(
            plugin,
            "plan",
            &request,
            &[("LOCALAPPDATA", temporary.path().as_os_str())],
        );
        assert_eq!(result["success"], true);
        assert_eq!(result["operations"], json!([]));
    }

    #[cfg(windows)]
    #[test]
    fn explicit_false_manages_only_the_configured_windows_update_property() {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("plugins");
        let plugins = discover(&root).unwrap();
        let plugin = plugins
            .iter()
            .find(|plugin| plugin.manifest.name == "windows-update")
            .unwrap();
        let request = json!({
            "protocol_version": 2,
            "plugin": plugin.manifest.name,
            "path": "system.windows.update",
            "configuration": { "restart_notifications": false },
            "context": {
                "scope": "system",
                "user_selector": null,
                "device": "test",
                "device_overlay": null,
                "user_sid": null,
                "elevated": false
            }
        });

        let result = run_plugin(plugin, "plan", &request, &[]);
        assert_eq!(result["success"], true);
        assert_eq!(
            result["state"]
                .as_object()
                .unwrap()
                .keys()
                .collect::<Vec<_>>(),
            vec!["restart_notifications"]
        );
        for operation in result["operations"].as_array().unwrap() {
            assert_eq!(operation["resource"]["id"], "restart_notifications");
            assert_eq!(operation["after"], 0);
        }
    }
}
