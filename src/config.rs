use std::path::Path;

use anyhow::{Context, Result, bail};
use serde_json::Value;

pub fn load(path: &Path) -> Result<Value> {
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("failed to read configuration {}", path.display()))?;
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .map(str::to_ascii_lowercase)
        .unwrap_or_default();

    let value = match extension.as_str() {
        "json" => serde_json::from_str(&text).context("invalid JSON")?,
        "yaml" | "yml" => serde_yaml::from_str(&text).context("invalid YAML")?,
        "toml" => {
            let value: toml::Value = toml::from_str(&text).context("invalid TOML")?;
            serde_json::to_value(value)
                .context("TOML contains a value that cannot be normalized")?
        }
        _ => bail!("unsupported configuration format; use .json, .yaml, .yml, or .toml"),
    };

    if !value.is_object() {
        bail!("the configuration root must be an object");
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loads_yaml_as_json_value() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.yaml");
        std::fs::write(&path, "version: 1\npackages: {}\n").unwrap();
        let value = load(&path).unwrap();
        assert_eq!(value["version"], 1);
    }
}
