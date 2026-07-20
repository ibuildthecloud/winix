use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::thread;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde_json::Value;

use crate::device::DeviceContext;
use crate::event::EventEmitter;
use crate::plugin::Plugin;

const ELEVATED_APPLY_SCRIPT: &str = r#"
try {
    $process = Start-Process -FilePath $env:WINIX_CFG_ELEVATED_EXECUTABLE `
        -ArgumentList @('elevated-operation', $env:WINIX_CFG_ELEVATED_PAYLOAD) `
        -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    exit $process.ExitCode
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
} finally {
}
"#;

const USER_TASK_START_SCRIPT: &str = r#"
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$arguments = '//B //NoLogo "' + $env:WINIX_CFG_USER_WRAPPER + '"'
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
$action = New-ScheduledTaskAction `
    -Execute $wscript `
    -Argument $arguments `
    -WorkingDirectory $env:WINIX_CFG_USER_WORKING_DIRECTORY
$principal = New-ScheduledTaskPrincipal `
    -UserId $sid `
    -LogonType Interactive `
    -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Hours 24)
Register-ScheduledTask `
    -TaskName $env:WINIX_CFG_USER_TASK `
    -Action $action `
    -Principal $principal `
    -Settings $settings `
    -Force | Out-Null
try {
    Start-ScheduledTask -TaskName $env:WINIX_CFG_USER_TASK
} catch {
    Unregister-ScheduledTask `
        -TaskName $env:WINIX_CFG_USER_TASK `
        -Confirm:$false `
        -ErrorAction SilentlyContinue
    throw
}
"#;

const USER_TASK_REMOVE_SCRIPT: &str = r#"
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Unregister-ScheduledTask `
    -TaskName $env:WINIX_CFG_USER_TASK `
    -Confirm:$false `
    -ErrorAction SilentlyContinue
"#;

const POWERSHELL_BOOTSTRAP_ARGUMENTS: &[&str] = &[
    "install",
    "--id",
    "Microsoft.PowerShell",
    "--exact",
    "--source",
    "winget",
    "--silent",
    "--force",
    "--accept-source-agreements",
    "--accept-package-agreements",
    "--disable-interactivity",
];

pub const REBOOT_REQUIRED_EXIT_CODE: i32 = 3010;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ElevatedApplyStatus {
    Completed,
    RebootRequired,
}

fn elevated_apply_status(code: Option<i32>) -> Result<ElevatedApplyStatus> {
    match code {
        Some(0) => Ok(ElevatedApplyStatus::Completed),
        Some(REBOOT_REQUIRED_EXIT_CODE) => Ok(ElevatedApplyStatus::RebootRequired),
        Some(code) => bail!("elevated system worker failed with exit code {code}"),
        None => bail!("elevated system worker terminated without an exit code"),
    }
}

static PWSH_EXECUTABLE: OnceLock<PathBuf> = OnceLock::new();

#[cfg(windows)]
struct OwnedHandle(windows_sys::Win32::Foundation::HANDLE);

#[cfg(windows)]
impl Drop for OwnedHandle {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: This wrapper exclusively owns a valid Win32 handle.
            unsafe { windows_sys::Win32::Foundation::CloseHandle(self.0) };
        }
    }
}

pub fn ensure_available() -> Result<&'static Path> {
    if PWSH_EXECUTABLE.get().is_none() {
        let executable = match resolve_compatible_pwsh()? {
            Some(executable) => executable,
            None => bootstrap_pwsh()?,
        };
        let _ = PWSH_EXECUTABLE.set(executable);
    }
    Ok(PWSH_EXECUTABLE
        .get()
        .expect("PowerShell runtime is initialized")
        .as_path())
}

pub fn initialize(executable: PathBuf) -> Result<()> {
    if let Some(existing) = PWSH_EXECUTABLE.get() {
        if existing != &executable {
            bail!(
                "PowerShell runtime was already initialized to {}",
                existing.display()
            );
        }
        return Ok(());
    }
    let _ = PWSH_EXECUTABLE.set(executable);
    Ok(())
}

#[cfg(windows)]
fn shell_unelevated_token() -> Result<OwnedHandle> {
    use std::mem::{size_of, zeroed};

    use windows_sys::Win32::Foundation::HANDLE;
    use windows_sys::Win32::Security::{
        EqualSid, GetTokenInformation, TOKEN_ELEVATION, TOKEN_QUERY, TOKEN_USER, TokenElevation,
        TokenPrimary, TokenType,
    };
    use windows_sys::Win32::System::RemoteDesktop::ProcessIdToSessionId;
    use windows_sys::Win32::System::Threading::{
        GetCurrentProcess, GetCurrentProcessId, OpenProcess, OpenProcessToken,
        PROCESS_QUERY_LIMITED_INFORMATION,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::{GetShellWindow, GetWindowThreadProcessId};

    fn user_sid(token: HANDLE) -> Result<Vec<usize>> {
        use windows_sys::Win32::Security::{GetTokenInformation, TokenUser};

        let mut required = 0;
        // SAFETY: A null buffer with length zero is the documented size-query form.
        unsafe {
            GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut required);
        }
        if required == 0 {
            return Err(std::io::Error::last_os_error())
                .context("failed to size token user information");
        }
        let words = (required as usize).div_ceil(size_of::<usize>());
        let mut buffer = vec![0usize; words];
        // SAFETY: The word buffer is suitably aligned and has at least `required` writable bytes.
        if unsafe {
            GetTokenInformation(
                token,
                TokenUser,
                buffer.as_mut_ptr().cast(),
                required,
                &mut required,
            )
        } == 0
        {
            return Err(std::io::Error::last_os_error())
                .context("failed to read token user information");
        }
        Ok(buffer)
    }

    let mut process_token: HANDLE = std::ptr::null_mut();
    // SAFETY: process_token points to initialized handle storage.
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut process_token) } == 0 {
        return Err(std::io::Error::last_os_error())
            .context("failed to open elevated process token");
    }
    let process_token = OwnedHandle(process_token);

    // GetShellWindow identifies the desktop shell for this window station. Constrain it further to
    // the coordinator's session and account before trusting its primary token.
    let shell_window = unsafe { GetShellWindow() };
    if shell_window.is_null() {
        bail!("the current Windows session has no desktop shell to provide an unelevated token");
    }
    let mut shell_process_id = 0;
    // SAFETY: shell_window is non-null and the process-id pointer is valid.
    if unsafe { GetWindowThreadProcessId(shell_window, &mut shell_process_id) } == 0 {
        return Err(std::io::Error::last_os_error())
            .context("failed to identify the desktop shell process");
    }
    let mut coordinator_session = 0;
    let mut shell_session = 0;
    // SAFETY: Both output pointers refer to initialized u32 storage.
    if unsafe { ProcessIdToSessionId(GetCurrentProcessId(), &mut coordinator_session) } == 0
        || unsafe { ProcessIdToSessionId(shell_process_id, &mut shell_session) } == 0
    {
        return Err(std::io::Error::last_os_error()).context("failed to verify shell session");
    }
    if coordinator_session != shell_session {
        bail!("the desktop shell belongs to a different Windows session");
    }

    // SAFETY: The PID was returned by User32 and no handle inheritance is requested.
    let shell_process =
        unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, shell_process_id) };
    if shell_process.is_null() {
        return Err(std::io::Error::last_os_error())
            .context("failed to open desktop shell process");
    }
    let shell_process = OwnedHandle(shell_process);
    let mut shell_token: HANDLE = std::ptr::null_mut();
    // SAFETY: shell_process is valid and shell_token points to initialized handle storage.
    if unsafe { OpenProcessToken(shell_process.0, TOKEN_QUERY, &mut shell_token) } == 0 {
        return Err(std::io::Error::last_os_error())
            .context("failed to inspect desktop shell token");
    }
    let shell_token = OwnedHandle(shell_token);

    let mut token_type = 0;
    let mut returned = 0;
    // SAFETY: token_type is writable storage of the documented TOKEN_TYPE size.
    if unsafe {
        GetTokenInformation(
            shell_token.0,
            TokenType,
            (&mut token_type as *mut i32).cast(),
            size_of_val(&token_type) as u32,
            &mut returned,
        )
    } == 0
        || token_type != TokenPrimary
    {
        bail!("the desktop shell does not have a usable primary token");
    }
    let mut elevation: TOKEN_ELEVATION = unsafe { zeroed() };
    // SAFETY: elevation is writable TOKEN_ELEVATION storage.
    if unsafe {
        GetTokenInformation(
            shell_token.0,
            TokenElevation,
            (&mut elevation as *mut TOKEN_ELEVATION).cast(),
            size_of::<TOKEN_ELEVATION>() as u32,
            &mut returned,
        )
    } == 0
    {
        return Err(std::io::Error::last_os_error())
            .context("failed to inspect desktop shell elevation");
    }
    if elevation.TokenIsElevated != 0 {
        bail!("the desktop shell is elevated; refusing to run user configuration through it");
    }

    let coordinator_user = user_sid(process_token.0)?;
    let shell_user = user_sid(shell_token.0)?;
    // SAFETY: Both buffers contain TOKEN_USER values whose SID storage lives with the buffers.
    let same_user = unsafe {
        let coordinator = &*(coordinator_user.as_ptr().cast::<TOKEN_USER>());
        let shell = &*(shell_user.as_ptr().cast::<TOKEN_USER>());
        EqualSid(coordinator.User.Sid, shell.User.Sid) != 0
    };
    if !same_user {
        bail!("the desktop shell belongs to a different Windows user");
    }

    Ok(shell_token)
}

#[cfg(windows)]
pub fn ensure_unelevated_worker_available() -> Result<()> {
    drop(shell_unelevated_token()?);
    Ok(())
}

fn resolve_compatible_pwsh() -> Result<Option<PathBuf>> {
    if let Some(override_path) = std::env::var_os("WINIX_PWSH") {
        let override_path = PathBuf::from(override_path);
        let version = powershell_version(&override_path).with_context(|| {
            format!(
                "WINIX_PWSH does not identify a working PowerShell executable: {}",
                override_path.display()
            )
        })?;
        if version.0 < 7 {
            bail!(
                "WINIX_PWSH identifies PowerShell {}.{}.{}, but Winix requires PowerShell 7 or newer",
                version.0,
                version.1,
                version.2
            );
        }
        return Ok(Some(override_path));
    }

    for candidate in powershell_candidates() {
        if let Ok((major, _, _)) = powershell_version(&candidate)
            && major >= 7
        {
            return Ok(Some(candidate));
        }
    }
    Ok(None)
}

fn powershell_candidates() -> Vec<PathBuf> {
    let mut candidates = vec![PathBuf::from("pwsh")];
    if let Some(program_files) = std::env::var_os("ProgramFiles") {
        candidates.push(
            PathBuf::from(program_files)
                .join("PowerShell")
                .join("7")
                .join("pwsh.exe"),
        );
    }
    if let Some(local_app_data) = std::env::var_os("LOCALAPPDATA") {
        let local_app_data = PathBuf::from(local_app_data);
        candidates.push(
            local_app_data
                .join("Programs")
                .join("PowerShell")
                .join("7")
                .join("pwsh.exe"),
        );
        candidates.push(
            local_app_data
                .join("Microsoft")
                .join("WindowsApps")
                .join("pwsh.exe"),
        );
    }
    candidates
}

fn powershell_version(executable: &Path) -> Result<(u32, u32, u32)> {
    let output = Command::new(executable)
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            "$PSVersionTable.PSVersion.ToString()",
        ])
        .output()
        .with_context(|| format!("failed to start {}", executable.display()))?;
    if !output.status.success() {
        bail!(
            "{} could not report its version: {}",
            executable.display(),
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    let rendered = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    let mut components = rendered.split('.');
    let major = components
        .next()
        .and_then(|value| value.parse().ok())
        .with_context(|| format!("PowerShell returned an invalid version {rendered:?}"))?;
    let minor = components
        .next()
        .and_then(|value| value.parse().ok())
        .unwrap_or(0);
    let patch = components
        .next()
        .and_then(|value| value.parse().ok())
        .unwrap_or(0);
    Ok((major, minor, patch))
}

fn bootstrap_pwsh() -> Result<PathBuf> {
    eprintln!(
        "PowerShell 7 was not found; installing the latest Microsoft.PowerShell with WinGet..."
    );
    let output = Command::new("winget.exe")
        .args(POWERSHELL_BOOTSTRAP_ARGUMENTS)
        .output()
        .context(
            "PowerShell 7 is required, and WinGet could not be started to install it; install Microsoft.PowerShell manually or set WINIX_PWSH",
        )?;
    if !output.status.success() {
        let code = output.status.code().unwrap_or(-1);
        bail!(
            "WinGet could not bootstrap PowerShell 7 (exit code {code}, 0x{:08X}).\nCommand: winget {}\nstdout:\n{}\nstderr:\n{}",
            code as u32,
            POWERSHELL_BOOTSTRAP_ARGUMENTS.join(" "),
            String::from_utf8_lossy(&output.stdout).trim_end(),
            String::from_utf8_lossy(&output.stderr).trim_end()
        );
    }

    let executable = resolve_compatible_pwsh()?.ok_or_else(|| {
        anyhow::anyhow!(
            "WinGet reported that PowerShell was installed, but Winix could not locate a compatible pwsh.exe.\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout).trim_end(),
            String::from_utf8_lossy(&output.stderr).trim_end()
        )
    })?;
    let version = powershell_version(&executable)?;
    eprintln!(
        "PowerShell {}.{}.{} is ready at {}.",
        version.0,
        version.1,
        version.2,
        executable.display()
    );
    Ok(executable)
}

pub fn is_elevated() -> Result<bool> {
    let output = Command::new(ensure_available()?)
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            "([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)",
        ])
        .output()
        .context("failed to determine whether the process is elevated")?;
    if !output.status.success() {
        bail!(
            "failed to determine elevation: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .trim()
        .eq_ignore_ascii_case("true"))
}

pub fn current_user_sid() -> Result<String> {
    let output = Command::new(ensure_available()?)
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            "[Security.Principal.WindowsIdentity]::GetCurrent().User.Value",
        ])
        .output()
        .context("failed to determine the current Windows user SID")?;
    if !output.status.success() {
        bail!(
            "failed to determine the current Windows user SID: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    let sid = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if sid.is_empty() {
        bail!("Windows returned an empty current-user SID");
    }
    Ok(sid)
}

pub fn elevated_capture_path() -> std::path::PathBuf {
    std::env::temp_dir().join(format!("winix-cfg-{}.output", uuid::Uuid::new_v4()))
}

pub fn request_elevated_apply(
    executable: &std::path::Path,
    payload: &str,
    capture_path: &std::path::Path,
    events: &mut EventEmitter,
) -> Result<ElevatedApplyStatus> {
    let mut child = Command::new(ensure_available()?)
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            ELEVATED_APPLY_SCRIPT,
        ])
        // Arguments following `pwsh -Command` are parsed as more PowerShell
        // source in some invocation forms. Environment variables preserve the
        // executable path and opaque base64 payload as data instead of code.
        .env("WINIX_CFG_ELEVATED_EXECUTABLE", executable)
        .env("WINIX_CFG_ELEVATED_PAYLOAD", payload)
        .env("WINIX_CFG_ELEVATED_CAPTURE", capture_path)
        .spawn()
        .context("failed to request administrator elevation")?;
    let mut capture_offset = 0;
    let mut replay_failure = None;
    let status = loop {
        if replay_failure.is_none()
            && let Err(error) = events.replay_appended_ndjson(capture_path, &mut capture_offset)
        {
            replay_failure = Some(error);
        }
        if let Some(status) = child
            .try_wait()
            .context("failed while waiting for elevated system apply")?
        {
            break status;
        }
        thread::sleep(Duration::from_millis(50));
    };
    if replay_failure.is_none()
        && let Err(error) = events.replay_appended_ndjson(capture_path, &mut capture_offset)
    {
        replay_failure = Some(error);
    }
    if let Some(error) = replay_failure {
        return Err(error).context("failed to stream elevated worker events");
    }
    elevated_apply_status(status.code())
}

#[cfg(windows)]
pub fn request_unelevated_apply(
    executable: &Path,
    request_path: &Path,
    capture_path: &Path,
    status_path: &Path,
    events: &mut EventEmitter,
) -> Result<ElevatedApplyStatus> {
    drop(shell_unelevated_token()?);
    let current_dir = std::env::current_dir().context("failed to resolve current directory")?;
    let powershell = ensure_available()?.to_path_buf();
    let task_name = format!("Winix user operation {}", uuid::Uuid::new_v4());
    let wrapper_path = request_path.with_extension("vbs");
    std::fs::write(
        &wrapper_path,
        hidden_worker_wrapper(executable, request_path),
    )
    .context("failed to write hidden current-user worker wrapper")?;
    let launch = Command::new(&powershell)
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            USER_TASK_START_SCRIPT,
        ])
        .env("WINIX_CFG_USER_WRAPPER", &wrapper_path)
        .env("WINIX_CFG_USER_WORKING_DIRECTORY", &current_dir)
        .env("WINIX_CFG_USER_TASK", &task_name)
        .output();
    let launch = match launch {
        Ok(launch) => launch,
        Err(error) => {
            let _ = std::fs::remove_file(&wrapper_path);
            return Err(error).context("failed to invoke Task Scheduler for current-user worker");
        }
    };
    if !launch.status.success() {
        let _ = std::fs::remove_file(&wrapper_path);
        bail!(
            "Task Scheduler could not start current-user worker: {}",
            String::from_utf8_lossy(&launch.stderr).trim()
        );
    }

    let mut capture_offset = 0;
    let mut replay_failure = None;
    let launch_deadline = std::time::Instant::now() + Duration::from_secs(30);
    let status_result = (|| -> Result<i32> {
        let mut started = false;
        loop {
            if replay_failure.is_none()
                && let Err(error) = events.replay_appended_ndjson(capture_path, &mut capture_offset)
            {
                replay_failure = Some(error);
            }
            started |= capture_path.is_file();
            if status_path.is_file() {
                let rendered = std::fs::read_to_string(status_path)
                    .context("failed to read current-user worker status")?;
                return rendered
                    .trim()
                    .parse::<i32>()
                    .context("current-user worker returned an invalid status");
            }
            if !started && std::time::Instant::now() >= launch_deadline {
                bail!("Task Scheduler did not start current-user worker within 30 seconds");
            }
            thread::sleep(Duration::from_millis(50));
        }
    })();

    let cleanup = Command::new(&powershell)
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            USER_TASK_REMOVE_SCRIPT,
        ])
        .env("WINIX_CFG_USER_TASK", &task_name)
        .output();
    let _ = std::fs::remove_file(&wrapper_path);
    let cleanup = cleanup.context("failed to remove current-user worker task")?;
    if !cleanup.status.success() {
        bail!(
            "failed to remove current-user worker task: {}",
            String::from_utf8_lossy(&cleanup.stderr).trim()
        );
    }

    let status = status_result?;
    if replay_failure.is_none()
        && let Err(error) = events.replay_appended_ndjson(capture_path, &mut capture_offset)
    {
        replay_failure = Some(error);
    }
    if let Some(error) = replay_failure {
        return Err(error).context("failed to stream current-user worker events");
    }
    elevated_apply_status(Some(status))
}

#[cfg(windows)]
fn hidden_worker_wrapper(executable: &Path, request_path: &Path) -> String {
    let command = format!(
        "\"{}\" user-operation \"{}\"",
        executable.display(),
        request_path.display()
    );
    let command = command.replace('"', "\"\"");
    format!(
        "Set shell = CreateObject(\"WScript.Shell\")\r\n\
         exitCode = shell.Run(\"{command}\", 0, True)\r\n\
         WScript.Quit exitCode\r\n"
    )
}

pub fn invoke(
    plugin: &Plugin,
    operation: &str,
    request: &Value,
    events: &mut EventEmitter,
    path: &str,
    scope: &str,
    device: &DeviceContext,
) -> Result<Value> {
    invoke_with_events(plugin, operation, request, |kind, record| {
        events.emit_plugin(kind, &plugin.manifest.name, path, scope, device, record);
    })
}

pub fn invoke_with_events(
    plugin: &Plugin,
    operation: &str,
    request: &Value,
    mut emit: impl FnMut(&str, Value),
) -> Result<Value> {
    let entrypoint = plugin.directory.join(&plugin.manifest.entrypoint);
    let mut child = Command::new(ensure_available()?)
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
        ])
        .arg(&entrypoint)
        .args(["-Operation", operation])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("failed to start PowerShell plugin {}", plugin.manifest.name))?;

    let input = serde_json::to_vec(request)?;
    child.stdin.take().expect("piped stdin").write_all(&input)?;

    let mut stderr = child.stderr.take().expect("piped stderr");
    let stderr_reader = thread::spawn(move || {
        let mut output = String::new();
        let _ = stderr.read_to_string(&mut output);
        output
    });
    let stdout = child.stdout.take().expect("piped stdout");
    let mut result = None;
    let mut protocol_error = None;
    for (index, line) in BufReader::new(stdout).lines().enumerate() {
        let line = match line {
            Ok(line) => line,
            Err(error) => {
                protocol_error = Some(format!("failed reading plugin stdout: {error}"));
                break;
            }
        };
        if line.trim().is_empty() {
            continue;
        }
        let mut record: Value = match serde_json::from_str(&line) {
            Ok(record) => record,
            Err(error) => {
                protocol_error = Some(format!(
                    "invalid NDJSON record on line {}: {error}",
                    index + 1
                ));
                continue;
            }
        };
        let record_type = record
            .get("type")
            .and_then(Value::as_str)
            .map(str::to_owned);
        match record_type.as_deref() {
            Some("event") => {
                if result.is_some() {
                    protocol_error = Some("plugin emitted an event after its result".into());
                    continue;
                }
                let Some(kind) = record
                    .get("kind")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                else {
                    protocol_error = Some("plugin event is missing a string kind".into());
                    continue;
                };
                if let Some(object) = record.as_object_mut() {
                    object.remove("type");
                    object.remove("kind");
                }
                emit(&kind, record);
            }
            Some("result") => {
                if result.is_some() {
                    protocol_error = Some("plugin emitted more than one result".into());
                    continue;
                }
                result = record.get("result").cloned();
                if result.is_none() {
                    protocol_error = Some("plugin result record is missing result data".into());
                }
            }
            Some(other) => protocol_error = Some(format!("unknown plugin record type {other:?}")),
            None => protocol_error = Some("plugin record is missing a string type".into()),
        }
    }

    let status = child.wait()?;
    let stderr = stderr_reader.join().unwrap_or_default();
    let failure = if !status.success() {
        Some(format!(
            "plugin exited with {}: {}",
            status,
            truncate(stderr.trim(), 4096)
        ))
    } else if let Some(error) = protocol_error {
        Some(error)
    } else if result.is_none() {
        Some("plugin exited without a final result".into())
    } else {
        None
    };

    if let Some(message) = failure {
        emit(
            "plugin_failed",
            serde_json::json!({
                "diagnostic": {
                    "severity": "error",
                    "code": "plugin.protocol.failed",
                    "message": message
                }
            }),
        );
        bail!("plugin {} failed during {operation}", plugin.manifest.name);
    }
    let result = result.expect("result presence checked");
    if result.get("protocol_version").and_then(Value::as_u64)
        != Some(plugin.manifest.protocol_version.into())
    {
        bail!(
            "plugin {} returned an incompatible protocol version",
            plugin.manifest.name
        );
    }
    Ok(result)
}

fn truncate(value: &str, maximum: usize) -> String {
    value.chars().take(maximum).collect()
}

#[cfg(test)]
mod tests {
    use super::{
        ELEVATED_APPLY_SCRIPT, ElevatedApplyStatus, POWERSHELL_BOOTSTRAP_ARGUMENTS,
        REBOOT_REQUIRED_EXIT_CODE, USER_TASK_REMOVE_SCRIPT, USER_TASK_START_SCRIPT,
        elevated_apply_status, hidden_worker_wrapper,
    };

    #[test]
    fn elevated_launcher_treats_values_as_environment_data() {
        assert!(ELEVATED_APPLY_SCRIPT.contains("$env:WINIX_CFG_ELEVATED_EXECUTABLE"));
        assert!(ELEVATED_APPLY_SCRIPT.contains("$env:WINIX_CFG_ELEVATED_PAYLOAD"));
        assert!(ELEVATED_APPLY_SCRIPT.contains("-WindowStyle Hidden"));
        assert!(!ELEVATED_APPLY_SCRIPT.contains("$args"));
    }

    #[test]
    fn user_task_is_interactive_limited_and_treats_paths_as_data() {
        assert!(USER_TASK_START_SCRIPT.contains("-LogonType Interactive"));
        assert!(USER_TASK_START_SCRIPT.contains("-RunLevel Limited"));
        assert!(USER_TASK_START_SCRIPT.contains("System32\\wscript.exe"));
        assert!(USER_TASK_START_SCRIPT.contains("$env:WINIX_CFG_USER_WRAPPER"));
        assert!(USER_TASK_START_SCRIPT.contains("Unregister-ScheduledTask"));
        assert!(USER_TASK_REMOVE_SCRIPT.contains("Unregister-ScheduledTask"));
    }

    #[test]
    fn user_worker_wrapper_launches_winix_hidden_and_waits() {
        let wrapper = hidden_worker_wrapper(
            std::path::Path::new(r"C:\Program Files\Winix\winix-cfg.exe"),
            std::path::Path::new(r"C:\Temp\worker.request"),
        );
        assert!(wrapper.contains(
            r#"shell.Run("""C:\Program Files\Winix\winix-cfg.exe"" user-operation ""C:\Temp\worker.request""", 0, True)"#
        ));
        assert!(wrapper.contains("WScript.Quit exitCode"));
    }

    #[test]
    fn bootstrap_installs_latest_powershell_without_a_version_pin() {
        assert_eq!(POWERSHELL_BOOTSTRAP_ARGUMENTS[0], "install");
        assert!(POWERSHELL_BOOTSTRAP_ARGUMENTS.contains(&"Microsoft.PowerShell"));
        assert!(POWERSHELL_BOOTSTRAP_ARGUMENTS.contains(&"--exact"));
        assert!(!POWERSHELL_BOOTSTRAP_ARGUMENTS.contains(&"--version"));
    }

    #[test]
    fn uses_windows_success_reboot_required_exit_code() {
        assert_eq!(REBOOT_REQUIRED_EXIT_CODE, 3010);
        assert_eq!(
            elevated_apply_status(Some(REBOOT_REQUIRED_EXIT_CODE)).unwrap(),
            ElevatedApplyStatus::RebootRequired
        );
        assert_eq!(
            elevated_apply_status(Some(0)).unwrap(),
            ElevatedApplyStatus::Completed
        );
        assert!(elevated_apply_status(Some(1)).is_err());
    }
}
