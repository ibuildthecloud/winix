use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Seek, SeekFrom, Write};
use std::time::{SystemTime, UNIX_EPOCH};

use clap::ValueEnum;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::device::DeviceContext;

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, ValueEnum)]
#[serde(rename_all = "snake_case")]
pub enum OutputFormat {
    #[default]
    Console,
    Ndjson,
    /// Raw NDJSON events annotated with elapsed and inter-event timing.
    Trace,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EngineEvent {
    pub protocol_version: u32,
    pub operation_id: String,
    pub sequence: u64,
    pub timestamp_ms: u64,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plugin: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scope: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_overlay: Option<String>,
    pub payload: Value,
}

pub trait EventSink {
    fn emit(&mut self, event: &EngineEvent);
}

pub struct EventEmitter {
    operation_id: String,
    sequence: u64,
    sinks: Vec<Box<dyn EventSink>>,
}

impl EventEmitter {
    pub fn new(format: OutputFormat) -> Self {
        let sink: Box<dyn EventSink> = match format {
            OutputFormat::Console => Box::new(ConsoleSink),
            OutputFormat::Ndjson => Box::new(NdjsonSink),
            OutputFormat::Trace => Box::new(TraceSink::default()),
        };
        let mut emitter = Self {
            operation_id: Uuid::new_v4().to_string(),
            sequence: 0,
            sinks: Vec::new(),
        };
        emitter.add_sink(sink);
        emitter
    }

    pub fn capture_only(path: &std::path::Path) -> std::io::Result<Self> {
        let file = OpenOptions::new().create(true).append(true).open(path)?;
        Ok(Self {
            operation_id: Uuid::new_v4().to_string(),
            sequence: 0,
            sinks: vec![Box::new(FileSink { file })],
        })
    }

    #[cfg(test)]
    pub fn replay_ndjson(&mut self, path: &std::path::Path) -> anyhow::Result<()> {
        let file = File::open(path)?;
        for (index, line) in BufReader::new(file).lines().enumerate() {
            let line = line?;
            if line.trim().is_empty() {
                continue;
            }
            let event: EngineEvent = serde_json::from_str(&line).map_err(|error| {
                anyhow::anyhow!("invalid elevated event on line {}: {error}", index + 1)
            })?;
            for sink in &mut self.sinks {
                sink.emit(&event);
            }
        }
        Ok(())
    }

    pub fn replay_appended_ndjson(
        &mut self,
        path: &std::path::Path,
        offset: &mut u64,
    ) -> anyhow::Result<()> {
        if !path.is_file() {
            return Ok(());
        }
        let mut file = File::open(path)?;
        let length = file.metadata()?.len();
        if *offset > length {
            anyhow::bail!(
                "elevated event capture was truncated from {} to {length} bytes",
                *offset
            );
        }
        file.seek(SeekFrom::Start(*offset))?;
        let mut reader = BufReader::new(file);
        loop {
            let mut line = String::new();
            let bytes_read = reader.read_line(&mut line)?;
            if bytes_read == 0 {
                break;
            }
            // The worker flushes one complete JSON record per line. Leave a
            // partially observed record for the next poll instead of parsing
            // data that is still being written.
            if !line.ends_with('\n') {
                break;
            }
            let record_offset = *offset;
            *offset += bytes_read as u64;
            let line = line.trim_end_matches(['\r', '\n']);
            if line.trim().is_empty() {
                continue;
            }
            let event: EngineEvent = serde_json::from_str(line).map_err(|error| {
                anyhow::anyhow!("invalid elevated event at byte offset {record_offset}: {error}")
            })?;
            for sink in &mut self.sinks {
                sink.emit(&event);
            }
        }
        Ok(())
    }

    pub fn add_sink(&mut self, sink: Box<dyn EventSink>) {
        self.sinks.push(sink);
    }

    pub fn emit(&mut self, kind: &str, payload: Value) {
        self.emit_enriched(kind, None, None, None, None, payload);
    }

    pub fn emit_plugin(
        &mut self,
        kind: &str,
        plugin: &str,
        path: &str,
        scope: &str,
        device: &DeviceContext,
        payload: Value,
    ) {
        self.emit_enriched(
            kind,
            Some(plugin),
            Some(path),
            Some(scope),
            Some(device),
            payload,
        );
    }

    pub fn run_operation<T>(
        &mut self,
        operation: &str,
        failure_code: &str,
        run: impl FnOnce(&mut Self) -> anyhow::Result<(T, Option<Value>)>,
    ) -> anyhow::Result<T> {
        self.emit("operation_started", operation_payload(operation, None));
        match run(self) {
            Ok((value, result)) => {
                self.emit("operation_completed", operation_payload(operation, result));
                Ok(value)
            }
            Err(error) => {
                self.emit(
                    "operation_failed",
                    json!({
                        "operation": operation,
                        "diagnostic": {
                            "severity": "error",
                            "code": failure_code,
                            "message": format!("{error:#}")
                        }
                    }),
                );
                Err(error)
            }
        }
    }

    fn emit_enriched(
        &mut self,
        kind: &str,
        plugin: Option<&str>,
        path: Option<&str>,
        scope: Option<&str>,
        device: Option<&DeviceContext>,
        payload: Value,
    ) {
        self.sequence += 1;
        let timestamp_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
            .min(u64::MAX as u128) as u64;
        let event = EngineEvent {
            protocol_version: 1,
            operation_id: self.operation_id.clone(),
            sequence: self.sequence,
            timestamp_ms,
            kind: kind.to_owned(),
            plugin: plugin.map(str::to_owned),
            path: path.map(str::to_owned),
            scope: scope.map(str::to_owned),
            device: device.map(|value| value.name.clone()),
            device_overlay: device.and_then(|value| value.overlay.clone()),
            payload,
        };
        for sink in &mut self.sinks {
            sink.emit(&event);
        }
    }
}

struct NdjsonSink;

impl EventSink for NdjsonSink {
    fn emit(&mut self, event: &EngineEvent) {
        println!(
            "{}",
            serde_json::to_string(event).expect("engine event is serializable")
        );
    }
}

#[derive(Default)]
struct TraceSink {
    first_timestamp_ms: Option<u64>,
    previous_timestamp_ms: Option<u64>,
}

#[derive(Serialize)]
struct TimedEvent<'a> {
    #[serde(flatten)]
    event: &'a EngineEvent,
    elapsed_ms: u64,
    delta_ms: u64,
}

impl TraceSink {
    fn annotate<'a>(&mut self, event: &'a EngineEvent) -> TimedEvent<'a> {
        let first = *self.first_timestamp_ms.get_or_insert(event.timestamp_ms);
        let elapsed_ms = event.timestamp_ms.saturating_sub(first);
        let delta_ms = self
            .previous_timestamp_ms
            .map(|previous| event.timestamp_ms.saturating_sub(previous))
            .unwrap_or(0);
        self.previous_timestamp_ms = Some(event.timestamp_ms);
        TimedEvent {
            event,
            elapsed_ms,
            delta_ms,
        }
    }
}

impl EventSink for TraceSink {
    fn emit(&mut self, event: &EngineEvent) {
        let timed = self.annotate(event);
        println!(
            "{}",
            serde_json::to_string(&timed).expect("timed engine event is serializable")
        );
    }
}

struct ConsoleSink;

impl EventSink for ConsoleSink {
    fn emit(&mut self, event: &EngineEvent) {
        for line in console_lines(event) {
            println!("{line}");
        }
    }
}

struct FileSink {
    file: File,
}

impl EventSink for FileSink {
    fn emit(&mut self, event: &EngineEvent) {
        let _ = writeln!(
            self.file,
            "{}",
            serde_json::to_string(event).expect("engine event is serializable")
        );
        let _ = self.file.flush();
    }
}

fn console_lines(event: &EngineEvent) -> Vec<String> {
    let prefix = event
        .plugin
        .as_deref()
        .map(|plugin| format!("{plugin}: "))
        .unwrap_or_default();
    match event.kind.as_str() {
        "operation_started" => vec![format!(
            "{} started",
            event.payload["operation"].as_str().unwrap_or("operation")
        )],
        "operation_completed" => vec![format!(
            "{} completed",
            event.payload["operation"].as_str().unwrap_or("operation")
        )],
        "operation_failed" => vec![format!("operation failed: {}", message(&event.payload))],
        "plugin_started" => vec![format!("{prefix}started")],
        "plugin_completed" => match event.payload["result"]["changed"].as_bool() {
            Some(true) => vec![format!("{prefix}completed (changed)")],
            Some(false) => vec![format!("{prefix}completed (no changes)")],
            None => vec![format!("{prefix}completed")],
        },
        "plugin_failed" => vec![format!("{prefix}failed: {}", message(&event.payload))],
        "resource_checking" => vec![format!("{prefix}checking {}", resource_id(&event.payload))],
        "resource_status" => {
            if let Some(operation) = event.payload["data"]["operation"].as_object() {
                vec![format!(
                    "{prefix}{}: planned {} ({} -> {})",
                    resource_id(&event.payload),
                    operation
                        .get("action")
                        .and_then(Value::as_str)
                        .unwrap_or("change"),
                    plan_value(operation.get("before")),
                    plan_value(operation.get("after"))
                )]
            } else {
                vec![format!(
                    "{prefix}{}: {}",
                    resource_id(&event.payload),
                    event.payload["data"]["status"]
                        .as_str()
                        .unwrap_or("observed")
                )]
            }
        }
        "resource_change_started" => vec![format!(
            "{prefix}{}: {} started",
            resource_id(&event.payload),
            event.payload["data"]["action"].as_str().unwrap_or("change")
        )],
        "resource_change_completed" => vec![format!(
            "{prefix}{}: {} completed",
            resource_id(&event.payload),
            event.payload["data"]["action"].as_str().unwrap_or("change")
        )],
        "diagnostic" => {
            let mut lines = vec![format!("{prefix}{}", message(&event.payload))];
            if let Some(help) = event.payload["diagnostic"]["help"].as_str() {
                lines.push(format!("{prefix}help: {help}"));
            }
            if let Some(path) = event.payload["diagnostic"]["path"].as_str() {
                lines.push(format!("{prefix}config: {path}"));
            }
            lines
        }
        "restart_required" => {
            let explanation = event.payload["message"]
                .as_str()
                .unwrap_or("System restart required.");
            let suffix = event.payload["exit_code"]
                .as_i64()
                .map(|code| format!(" (exit code {code})"))
                .unwrap_or_default();
            vec![format!("{prefix}{explanation}{suffix}")]
        }
        _ => vec![format!("{prefix}{}", event.kind)],
    }
}

fn resource_id(payload: &Value) -> &str {
    payload["resource"]["id"].as_str().unwrap_or("resource")
}

fn message(payload: &Value) -> &str {
    payload["diagnostic"]["message"]
        .as_str()
        .or_else(|| payload["message"].as_str())
        .unwrap_or("unknown error")
}

fn plan_value(value: Option<&Value>) -> String {
    let Some(value) = value else {
        return "unknown".into();
    };
    if let Some(object) = value.as_object() {
        if object.get("installed") == Some(&Value::Bool(false)) {
            return "absent".into();
        }
        if let Some(version) = object.get("version").and_then(Value::as_str) {
            return version.into();
        }
    }
    match value {
        Value::String(value) => value.clone(),
        other => serde_json::to_string(other).unwrap_or_else(|_| "unknown".into()),
    }
}

pub fn operation_payload(operation: &str, result: Option<Value>) -> Value {
    let mut payload = json!({ "operation": operation });
    if let Some(result) = result {
        payload["result"] = result;
    }
    payload
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::rc::Rc;

    struct Collector(Rc<RefCell<Vec<EngineEvent>>>);

    impl EventSink for Collector {
        fn emit(&mut self, event: &EngineEvent) {
            self.0.borrow_mut().push(event.clone());
        }
    }

    #[test]
    fn emitted_events_are_sequenced() {
        let collected = Rc::new(RefCell::new(Vec::new()));
        let also_collected = Rc::new(RefCell::new(Vec::new()));
        let mut emitter = EventEmitter {
            operation_id: "test".into(),
            sequence: 0,
            sinks: vec![Box::new(Collector(collected.clone()))],
        };
        emitter.add_sink(Box::new(Collector(also_collected.clone())));
        emitter.emit("operation_started", json!({}));
        emitter.emit("operation_completed", json!({}));
        let collected = collected.borrow();
        assert_eq!(collected.len(), 2);
        assert_eq!(collected[0].sequence, 1);
        assert_eq!(collected[1].sequence, 2);
        assert_eq!(collected[0].operation_id, "test");
        assert_eq!(also_collected.borrow().len(), 2);
    }

    #[test]
    fn reported_operation_emits_one_completion_on_success() {
        let collected = Rc::new(RefCell::new(Vec::new()));
        let mut emitter = EventEmitter {
            operation_id: "test".into(),
            sequence: 0,
            sinks: vec![Box::new(Collector(collected.clone()))],
        };

        let value = emitter
            .run_operation("validate", "execution.validate.failed", |_| {
                Ok((42, Some(json!({ "valid": true }))))
            })
            .unwrap();

        assert_eq!(value, 42);
        let events = collected.borrow();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].kind, "operation_started");
        assert_eq!(events[1].kind, "operation_completed");
        assert_eq!(events[1].payload["operation"], "validate");
        assert_eq!(events[1].payload["result"]["valid"], true);
    }

    #[test]
    fn reported_operation_emits_one_failure_and_preserves_error() {
        let collected = Rc::new(RefCell::new(Vec::new()));
        let mut emitter = EventEmitter {
            operation_id: "test".into(),
            sequence: 0,
            sinks: vec![Box::new(Collector(collected.clone()))],
        };

        let error = emitter
            .run_operation::<()>("plan", "execution.plan.failed", |_| {
                anyhow::bail!("deliberate failure")
            })
            .unwrap_err();

        assert_eq!(error.to_string(), "deliberate failure");
        let events = collected.borrow();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].kind, "operation_started");
        assert_eq!(events[1].kind, "operation_failed");
        assert_eq!(events[1].payload["operation"], "plan");
        assert_eq!(
            events[1].payload["diagnostic"]["code"],
            "execution.plan.failed"
        );
        assert_eq!(
            events[1].payload["diagnostic"]["message"],
            "deliberate failure"
        );
    }

    #[test]
    fn elevated_capture_replays_raw_events_to_parent_sinks() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("events.ndjson");
        let mut child = EventEmitter::capture_only(&path).unwrap();
        child.emit("operation_started", json!({ "operation": "apply" }));
        drop(child);

        let collected = Rc::new(RefCell::new(Vec::new()));
        let mut parent = EventEmitter {
            operation_id: "parent".into(),
            sequence: 0,
            sinks: vec![Box::new(Collector(collected.clone()))],
        };
        parent.replay_ndjson(&path).unwrap();

        let events = collected.borrow();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, "operation_started");
        assert_eq!(events[0].payload["operation"], "apply");
    }

    #[test]
    fn elevated_capture_streams_complete_appended_records_once() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("events.ndjson");
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .unwrap();
        let first = serde_json::to_string(&EngineEvent {
            protocol_version: 1,
            operation_id: "worker".into(),
            sequence: 1,
            timestamp_ms: 1,
            kind: "plugin_started".into(),
            plugin: Some("windows-wsl".into()),
            path: None,
            scope: Some("system".into()),
            device: None,
            device_overlay: None,
            payload: json!({ "operation": "plan" }),
        })
        .unwrap();
        let split = first.len() / 2;
        file.write_all(&first.as_bytes()[..split]).unwrap();
        file.flush().unwrap();

        let collected = Rc::new(RefCell::new(Vec::new()));
        let mut parent = EventEmitter {
            operation_id: "parent".into(),
            sequence: 0,
            sinks: vec![Box::new(Collector(collected.clone()))],
        };
        let mut offset = 0;
        parent.replay_appended_ndjson(&path, &mut offset).unwrap();
        assert!(collected.borrow().is_empty());
        assert_eq!(offset, 0);

        writeln!(file, "{}", &first[split..]).unwrap();
        file.flush().unwrap();
        parent.replay_appended_ndjson(&path, &mut offset).unwrap();
        parent.replay_appended_ndjson(&path, &mut offset).unwrap();

        let events = collected.borrow();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].kind, "plugin_started");
        assert_eq!(events[0].plugin.as_deref(), Some("windows-wsl"));
    }

    #[test]
    fn console_renders_concrete_planned_transition() {
        let event = EngineEvent {
            protocol_version: 1,
            operation_id: "test".into(),
            sequence: 1,
            timestamp_ms: 0,
            kind: "resource_status".into(),
            plugin: Some("winget".into()),
            path: None,
            scope: None,
            device: None,
            device_overlay: None,
            payload: json!({
                "resource": { "id": "Example.Package" },
                "data": {
                    "status": "change_required",
                    "operation": {
                        "action": "upgrade",
                        "before": { "installed": true, "version": "1.0.0" },
                        "after": { "installed": true, "version": "2.0.0" }
                    }
                }
            }),
        };

        assert_eq!(
            console_lines(&event),
            vec!["winget: Example.Package: planned upgrade (1.0.0 -> 2.0.0)"]
        );
    }

    #[test]
    fn console_explains_required_restart_and_exit_code() {
        let event = EngineEvent {
            protocol_version: 1,
            operation_id: "test".into(),
            sequence: 1,
            timestamp_ms: 0,
            kind: "restart_required".into(),
            plugin: None,
            path: None,
            scope: None,
            device: None,
            device_overlay: None,
            payload: json!({
                "message": "System restart required. Restart Windows, then run Winix again.",
                "exit_code": 3010
            }),
        };

        assert_eq!(
            console_lines(&event),
            vec![
                "System restart required. Restart Windows, then run Winix again. (exit code 3010)"
            ]
        );
    }

    #[test]
    fn trace_annotates_raw_events_with_elapsed_and_delta_time() {
        let mut sink = TraceSink::default();
        let first = EngineEvent {
            protocol_version: 1,
            operation_id: "test".into(),
            sequence: 1,
            timestamp_ms: 1_000,
            kind: "operation_started".into(),
            plugin: None,
            path: None,
            scope: None,
            device: None,
            device_overlay: None,
            payload: json!({ "operation": "plan" }),
        };
        let mut second = first.clone();
        second.sequence = 2;
        second.timestamp_ms = 1_125;
        second.kind = "plugin_started".into();

        let first = serde_json::to_value(sink.annotate(&first)).unwrap();
        let second = serde_json::to_value(sink.annotate(&second)).unwrap();

        assert_eq!(first["elapsed_ms"], 0);
        assert_eq!(first["delta_ms"], 0);
        assert_eq!(second["elapsed_ms"], 125);
        assert_eq!(second["delta_ms"], 125);
        assert_eq!(second["kind"], "plugin_started");
        assert_eq!(second["payload"]["operation"], "plan");
    }
}
