use std::fs::File;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;
use std::sync::Arc;
use std::sync::Mutex;
use std::time::SystemTime;
use std::time::UNIX_EPOCH;

use serde_json::json;

#[derive(Clone)]
pub struct TraceLog {
    file: Option<Arc<Mutex<File>>>,
}

impl TraceLog {
    pub fn open(path: Option<&Path>) -> anyhow::Result<Self> {
        let Some(path) = path else {
            return Ok(Self { file: None });
        };

        if let Some(parent) = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
        {
            std::fs::create_dir_all(parent)?;
        }

        let file = OpenOptions::new().create(true).append(true).open(path)?;
        Ok(Self {
            file: Some(Arc::new(Mutex::new(file))),
        })
    }

    pub fn event(&self, name: &str, fields: serde_json::Value) {
        let Some(file) = &self.file else {
            return;
        };

        let timestamp_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_millis())
            .unwrap_or_default();
        let payload = json!({
            "time_ms": timestamp_ms,
            "event": name,
            "fields": fields,
        });

        if let Ok(mut file) = file.lock() {
            let _ = writeln!(file, "{payload}");
        }
    }
}
