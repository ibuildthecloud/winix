use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceContext {
    pub name: String,
    pub overlay: Option<String>,
    #[serde(default)]
    pub user_sid: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ResolvedDocument {
    pub document: Value,
    pub context: DeviceContext,
}

pub fn resolve(document: &Value) -> Result<ResolvedDocument> {
    let name = std::env::var("COMPUTERNAME").map_err(|_| {
        anyhow::anyhow!("COMPUTERNAME is not set; unable to select a device overlay")
    })?;
    let mut resolved = resolve_for(document, &name)?;
    resolved.context.user_sid = Some(crate::powershell::current_user_sid()?);
    Ok(resolved)
}

pub fn resolve_for(document: &Value, device_name: &str) -> Result<ResolvedDocument> {
    if device_name.trim().is_empty() {
        bail!("device name cannot be empty");
    }

    let mut effective = document.clone();
    let devices = effective
        .as_object_mut()
        .and_then(|root| root.remove("devices"));
    let mut matches = Vec::new();
    if let Some(devices) = devices {
        let devices = devices
            .as_object()
            .ok_or_else(|| anyhow::anyhow!("devices must be an object"))?;
        for (name, overlay) in devices {
            if name.eq_ignore_ascii_case(device_name) {
                matches.push((name.clone(), overlay.clone()));
            }
        }
    }

    if matches.len() > 1 {
        bail!(
            "multiple device keys match {device_name:?} case-insensitively: {}",
            matches
                .iter()
                .map(|(name, _)| name.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        );
    }

    let overlay_name = matches.first().map(|(name, _)| name.clone());
    if let Some((_, overlay)) = matches.into_iter().next() {
        for section in ["system", "users"] {
            let Some(overlay_section) = overlay.get(section) else {
                continue;
            };
            let root = effective
                .as_object_mut()
                .expect("validated configuration root is an object");
            let target = root
                .entry(section.to_owned())
                .or_insert_with(|| Value::Object(Map::new()));
            deep_merge(target, overlay_section.clone());
        }
    }

    Ok(ResolvedDocument {
        document: effective,
        context: DeviceContext {
            name: device_name.to_owned(),
            overlay: overlay_name,
            user_sid: None,
        },
    })
}

fn deep_merge(base: &mut Value, overlay: Value) {
    match (base, overlay) {
        (Value::Object(base), Value::Object(overlay)) => {
            for (key, value) in overlay {
                match base.get_mut(&key) {
                    Some(existing) => deep_merge(existing, value),
                    None => {
                        base.insert(key, value);
                    }
                }
            }
        }
        (base, overlay) => *base = overlay,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn overlays_matching_device_case_insensitively() {
        let source = json!({
            "version": 1,
            "users": { "current": { "settings": { "theme": "dark", "values": [1, 2] } } },
            "devices": {
                "DEV-LAPTOP": {
                    "users": { "current": { "settings": { "scale": 150, "values": [3] } } }
                }
            }
        });
        let resolved = resolve_for(&source, "dev-laptop").unwrap();
        assert_eq!(resolved.context.overlay.as_deref(), Some("DEV-LAPTOP"));
        assert_eq!(
            resolved.document["users"]["current"]["settings"],
            json!({ "theme": "dark", "scale": 150, "values": [3] })
        );
        assert!(resolved.document.get("devices").is_none());
    }

    #[test]
    fn leaves_global_configuration_when_no_device_matches() {
        let source = json!({
            "version": 1,
            "system": { "settings": { "enabled": true } },
            "devices": { "other": { "system": { "settings": { "enabled": false } } } }
        });
        let resolved = resolve_for(&source, "this-device").unwrap();
        assert_eq!(resolved.context.overlay, None);
        assert_eq!(resolved.document["system"]["settings"]["enabled"], true);
    }

    #[test]
    fn rejects_ambiguous_case_insensitive_names() {
        let source = json!({
            "version": 1,
            "devices": { "laptop": {}, "LAPTOP": {} }
        });
        assert!(resolve_for(&source, "Laptop").is_err());
    }
}
