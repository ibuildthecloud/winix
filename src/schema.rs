use anyhow::{Context, Result, bail};
use serde_json::{Map, Value, json};

use crate::plugin::{Placement, Plugin};

pub fn compose(plugins: &[Plugin]) -> Result<Value> {
    let mut root = json!({
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://winix.dev/schemas/winix-cfg.json",
        "title": "Winix configuration",
        "type": "object",
        "required": ["version"],
        "properties": {
            "$schema": { "type": "string" },
            "version": { "const": 1 },
            "system": namespace_schema(),
            "users": {
                "type": "object",
                "properties": {
                    "current": namespace_schema()
                },
                "additionalProperties": false
            }
        },
        "additionalProperties": false,
        "$defs": { "plugins": {} }
    });

    for plugin in plugins {
        root["$defs"]["plugins"][&plugin.manifest.name] = plugin.schema.clone();
        if plugin.supports(Placement::System) {
            let system = &mut root["properties"]["system"];
            insert_path(system, &plugin.manifest.path, &plugin.manifest.name)?;
        }
        if plugin.supports(Placement::User) {
            let current = &mut root["properties"]["users"]["properties"]["current"];
            insert_path(current, &plugin.manifest.path, &plugin.manifest.name)?;
        }
    }

    let system_schema = root["properties"]["system"].clone();
    let users_schema = root["properties"]["users"].clone();
    root["properties"]["devices"] = json!({
        "type": "object",
        "description": "Device-specific overlays keyed by Windows computer name.",
        "additionalProperties": {
            "type": "object",
            "properties": {
                "system": system_schema,
                "users": users_schema
            },
            "additionalProperties": false
        }
    });
    Ok(root)
}

fn insert_path(root: &mut Value, path: &str, plugin_name: &str) -> Result<()> {
    let segments: Vec<_> = path.split('.').collect();
    insert_segments(root, &segments, path, plugin_name)
}

fn insert_segments(
    node: &mut Value,
    segments: &[&str],
    full_path: &str,
    plugin_name: &str,
) -> Result<()> {
    let (segment, remaining) = segments
        .split_first()
        .context("plugin path must contain at least one segment")?;
    let properties = node
        .get_mut("properties")
        .and_then(Value::as_object_mut)
        .context("schema namespace is missing properties")?;

    if remaining.is_empty() {
        if properties.contains_key(*segment) {
            bail!("schema path collision at {full_path}");
        }
        properties.insert(
            (*segment).to_owned(),
            json!({ "$ref": format!("#/$defs/plugins/{plugin_name}") }),
        );
        return Ok(());
    }

    let child = properties
        .entry((*segment).to_owned())
        .or_insert_with(namespace_schema);
    if child.get("$ref").is_some() {
        bail!("schema path collision at {full_path}");
    }
    insert_segments(child, remaining, full_path, plugin_name)
}

fn namespace_schema() -> Value {
    let mut value = Map::new();
    value.insert("type".into(), Value::String("object".into()));
    value.insert("properties".into(), Value::Object(Map::new()));
    value.insert("additionalProperties".into(), Value::Bool(false));
    Value::Object(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plugin::{Manifest, PROTOCOL_VERSION, Placement, Plugin, Requirements};
    use std::collections::BTreeSet;
    use std::path::PathBuf;

    #[test]
    fn composes_registered_path() {
        let plugin = Plugin {
            directory: PathBuf::new(),
            manifest: Manifest {
                protocol_version: PROTOCOL_VERSION,
                name: "test".into(),
                path: "windows.test".into(),
                placements: BTreeSet::from([Placement::User]),
                entrypoint: "plugin.ps1".into(),
                schema: "schema.json".into(),
                requires: Requirements::default(),
            },
            schema: json!({"type": "object"}),
        };
        let schema = compose(&[plugin]).unwrap();
        assert_eq!(
            schema["properties"]["users"]["properties"]["current"]["properties"]["windows"]["properties"]
                ["test"]["$ref"],
            "#/$defs/plugins/test"
        );
    }

    #[test]
    fn separates_system_and_user_placements() {
        let plugin = Plugin {
            directory: PathBuf::new(),
            manifest: Manifest {
                protocol_version: PROTOCOL_VERSION,
                name: "both".into(),
                path: "packages.test".into(),
                placements: BTreeSet::from([Placement::System, Placement::User]),
                entrypoint: "plugin.ps1".into(),
                schema: "schema.json".into(),
                requires: Requirements::default(),
            },
            schema: json!({"type": "object"}),
        };
        let schema = compose(&[plugin]).unwrap();
        assert!(schema["properties"]["system"]["properties"]["packages"].is_object());
        assert!(
            schema["properties"]["users"]["properties"]["current"]["properties"]["packages"]
                .is_object()
        );
        assert!(
            schema["properties"]["devices"]["additionalProperties"]["properties"]["system"]
                ["properties"]["packages"]
                .is_object()
        );
        assert!(
            schema["properties"]["devices"]["additionalProperties"]["properties"]["users"]
                ["properties"]["current"]["properties"]["packages"]
                .is_object()
        );
    }

    #[test]
    fn checked_in_examples_match_the_composed_schema() {
        let repository = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let plugins = crate::plugin::discover(&repository.join("plugins")).unwrap();

        for relative_path in ["examples/quickstart.yaml", "examples/workstation.yaml"] {
            let path = repository.join(relative_path);
            let document = crate::config::load(&path)
                .unwrap_or_else(|error| panic!("failed to load {relative_path}: {error:#}"));
            crate::engine::validate_document(&document, &plugins).unwrap_or_else(|error| {
                panic!("{relative_path} does not match the composed schema: {error:#}")
            });
        }
    }
}
