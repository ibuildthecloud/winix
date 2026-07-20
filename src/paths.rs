use std::path::PathBuf;

use anyhow::{Context, Result, bail};

const CONFIG_ENV: &str = "WINIX_CONFIG";
const PLUGINS_ENV: &str = "WINIX_PLUGINS";

pub fn config(explicit: Option<PathBuf>) -> Result<PathBuf> {
    config_with(explicit, |name| std::env::var_os(name).map(PathBuf::from))
}

pub fn plugins(explicit: Option<PathBuf>) -> Result<PathBuf> {
    plugins_with(explicit, |name| std::env::var_os(name).map(PathBuf::from))
}

fn config_with<F>(explicit: Option<PathBuf>, env: F) -> Result<PathBuf>
where
    F: Fn(&str) -> Option<PathBuf>,
{
    if let Some(path) = explicit {
        return Ok(path);
    }
    if let Some(path) = env(CONFIG_ENV).filter(|path| !path.as_os_str().is_empty()) {
        return Ok(path);
    }
    let app_data = env("APPDATA")
        .filter(|path| !path.as_os_str().is_empty())
        .context("APPDATA is not set; provide a configuration path or set WINIX_CONFIG")?;
    Ok(app_data.join("Winix").join("config.yaml"))
}

fn plugins_with<F>(explicit: Option<PathBuf>, env: F) -> Result<PathBuf>
where
    F: Fn(&str) -> Option<PathBuf>,
{
    if let Some(path) = explicit {
        return Ok(path);
    }
    if let Some(path) = env(PLUGINS_ENV).filter(|path| !path.as_os_str().is_empty()) {
        return Ok(path);
    }
    if cfg!(feature = "development-paths") {
        return Ok(PathBuf::from("plugins"));
    }
    let program_files = env("ProgramFiles")
        .filter(|path| !path.as_os_str().is_empty())
        .ok_or_else(|| {
            anyhow::anyhow!("ProgramFiles is not set; provide --plugins-dir or set WINIX_PLUGINS")
        })?;
    let path = program_files.join("Winix").join("plugins");
    if path.as_os_str().is_empty() {
        bail!("resolved plugin path is empty");
    }
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn environment(values: &[(&str, &str)]) -> impl Fn(&str) -> Option<PathBuf> {
        let values: HashMap<String, PathBuf> = values
            .iter()
            .map(|(key, value)| ((*key).to_owned(), PathBuf::from(value)))
            .collect();
        move |name| values.get(name).cloned()
    }

    #[test]
    fn explicit_config_has_highest_precedence() {
        let path = config_with(
            Some(PathBuf::from("explicit.yaml")),
            environment(&[(CONFIG_ENV, "environment.yaml"), ("APPDATA", "appdata")]),
        )
        .unwrap();
        assert_eq!(path, PathBuf::from("explicit.yaml"));
    }

    #[test]
    fn config_environment_precedes_app_data() {
        let path = config_with(
            None,
            environment(&[(CONFIG_ENV, "environment.yaml"), ("APPDATA", "appdata")]),
        )
        .unwrap();
        assert_eq!(path, PathBuf::from("environment.yaml"));
    }

    #[test]
    fn config_defaults_to_roaming_app_data() {
        let path = config_with(None, environment(&[("APPDATA", "roaming")])).unwrap();
        assert_eq!(path, PathBuf::from("roaming/Winix/config.yaml"));
    }

    #[test]
    fn explicit_plugins_have_highest_precedence() {
        let path = plugins_with(
            Some(PathBuf::from("explicit-plugins")),
            environment(&[(PLUGINS_ENV, "environment-plugins")]),
        )
        .unwrap();
        assert_eq!(path, PathBuf::from("explicit-plugins"));
    }

    #[test]
    fn plugin_environment_precedes_compile_time_default() {
        let path =
            plugins_with(None, environment(&[(PLUGINS_ENV, "environment-plugins")])).unwrap();
        assert_eq!(path, PathBuf::from("environment-plugins"));
    }
}
