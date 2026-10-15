use std::collections::VecDeque;
use std::fmt::Debug;
use std::io::Read;
use std::io::Write;
use std::net::Shutdown;
use std::net::TcpStream;
use std::net::ToSocketAddrs;
use std::sync::Arc;
use std::sync::Condvar;
use std::sync::Mutex;
use std::time::Duration;
use std::time::Instant;

use anyhow::anyhow;
use serde::de::DeserializeOwned;
use serde::Serialize;

const MAX_WAITING_REQUESTS: usize = 8;
const CIRCUIT_FAILURE_THRESHOLD: u32 = 3;
const CIRCUIT_COOLDOWN: Duration = Duration::from_secs(2);
const CANCEL_POLL_INTERVAL: Duration = Duration::from_millis(10);

#[derive(Clone, Copy, Debug)]
pub(crate) enum BridgeRequestClass {
    Interactive,
    Lifecycle,
    ReadOnly,
    Mutating,
}

impl BridgeRequestClass {
    pub(crate) fn deadline(self, configured_timeout: Duration) -> Duration {
        match self {
            Self::Interactive => configured_timeout.min(Duration::from_secs(1)),
            Self::Lifecycle => Duration::from_secs(2),
            Self::ReadOnly => Duration::from_secs(10),
            Self::Mutating => Duration::from_secs(30),
        }
    }
}

#[derive(Clone)]
pub(crate) struct BridgeRequestControl {
    cancelled: Arc<dyn Fn() -> bool + Send + Sync>,
}

impl Debug for BridgeRequestControl {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BridgeRequestControl")
            .finish_non_exhaustive()
    }
}

impl Default for BridgeRequestControl {
    fn default() -> Self {
        Self::new(|| false)
    }
}

impl BridgeRequestControl {
    pub(crate) fn new(cancelled: impl Fn() -> bool + Send + Sync + 'static) -> Self {
        Self {
            cancelled: Arc::new(cancelled),
        }
    }

    fn is_cancelled(&self) -> bool {
        (self.cancelled)()
    }
}

#[derive(Debug)]
pub(crate) struct BridgeRuntimeUnavailable {
    message: String,
}

impl std::fmt::Display for BridgeRuntimeUnavailable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "bridge runtime unavailable: {}", self.message)
    }
}

impl std::error::Error for BridgeRuntimeUnavailable {}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct BridgeRuntimeDebugInfo {
    pub active: bool,
    pub waiting: usize,
    pub consecutive_failures: u32,
    pub circuit_open: bool,
    pub circuit_remaining_ms: u64,
    active_operation: Option<ActiveOperationDebugInfo>,
    recent_requests: Vec<BridgeRequestRecord>,
}

pub(crate) trait BridgeRequest: Serialize {
    fn request_id(&self) -> &str;
    fn operation(&self) -> &str;
}

#[derive(Clone, Debug, Default, serde::Deserialize, Serialize)]
pub(crate) struct BridgeHandlerDebugInfo {
    column_index: u32,
    #[serde(rename = "type")]
    column_type: String,
    rows: usize,
    distinct: usize,
    returned: usize,
    cache_hit: bool,
    filter_ms: f64,
    keys_ms: f64,
    count_ms: f64,
    labels_ms: f64,
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct BridgeExchangeTrace {
    stage: &'static str,
    connect_ms: u64,
    write_ms: u64,
    first_byte_ms: Option<u64>,
    response_bytes: usize,
    handler: Option<BridgeHandlerDebugInfo>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct BridgeRequestRecord {
    request_id: String,
    operation: String,
    queue_ms: u64,
    total_ms: u64,
    completed_at_ms: u64,
    success: bool,
    exchange: BridgeExchangeTrace,
}

#[derive(Debug)]
struct ActiveOperation {
    request_id: String,
    operation: String,
    started: Instant,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ActiveOperationDebugInfo {
    request_id: String,
    operation: String,
    age_ms: u64,
}

fn elapsed_ms(started: Instant) -> u64 {
    started.elapsed().as_millis().min(u128::from(u64::MAX)) as u64
}

pub(crate) trait BridgeTransport: Debug + Send + Sync {
    fn exchange(
        &self,
        host: &str,
        port: u16,
        payload: &[u8],
        deadline: Instant,
        trace: &mut BridgeExchangeTrace,
    ) -> anyhow::Result<Vec<u8>>;
}

#[derive(Debug, Default)]
pub(crate) struct TcpBridgeTransport;

impl BridgeTransport for TcpBridgeTransport {
    fn exchange(
        &self,
        host: &str,
        port: u16,
        payload: &[u8],
        deadline: Instant,
        trace: &mut BridgeExchangeTrace,
    ) -> anyhow::Result<Vec<u8>> {
        trace.stage = "connect";
        let connect_start = Instant::now();
        let addresses = (host, port).to_socket_addrs()?.collect::<Vec<_>>();
        if addresses.is_empty() {
            return Err(anyhow!("bridge host resolved to no socket addresses"));
        }

        let mut last_error = None;
        let mut stream = None;
        for address in addresses {
            let remaining = remaining(deadline)?;
            match TcpStream::connect_timeout(&address, remaining) {
                Ok(connected) => {
                    stream = Some(connected);
                    break;
                },
                Err(err) => last_error = Some(err),
            }
        }
        let mut stream = stream.ok_or_else(|| {
            last_error
                .map(anyhow::Error::from)
                .unwrap_or_else(|| anyhow!("bridge connection failed"))
        })?;

        trace.connect_ms = elapsed_ms(connect_start);
        trace.stage = "write_request";
        let write_start = Instant::now();
        let write_timeout = remaining(deadline)?;
        stream.set_write_timeout(Some(write_timeout))?;
        stream.write_all(payload)?;
        stream.write_all(b"\n")?;
        stream.shutdown(Shutdown::Write)?;

        trace.write_ms = elapsed_ms(write_start);
        trace.stage = "wait_first_byte";
        let read_start = Instant::now();
        let mut response = Vec::new();
        let mut chunk = [0_u8; 8192];
        loop {
            stream.set_read_timeout(Some(remaining(deadline)?))?;
            let read = stream.read(&mut chunk)?;
            if read == 0 {
                return Ok(response);
            }
            if trace.first_byte_ms.is_none() {
                trace.first_byte_ms = Some(elapsed_ms(read_start));
            }
            trace.stage = "read_response";
            trace.response_bytes += read;
            response.extend_from_slice(&chunk[..read]);
            if let Ok(value) = serde_json::from_slice::<serde_json::Value>(&response) {
                trace.handler = value
                    .get("diagnostics")
                    .and_then(|details| serde_json::from_value(details.clone()).ok());
                return Ok(response);
            }
        }
    }
}

#[derive(Debug, Default)]
struct QueueState {
    active: bool,
    waiting: usize,
    operation: Option<ActiveOperation>,
    recent: VecDeque<BridgeRequestRecord>,
    degraded_since: Option<Instant>,
    suppressed_failures: u64,
}

#[derive(Debug, Default)]
struct CircuitState {
    connection_identity: Option<u64>,
    consecutive_failures: u32,
    open_until: Option<Instant>,
    half_open_active: bool,
}

#[derive(Debug)]
pub(crate) struct BridgeRuntime {
    queue: Arc<(Mutex<QueueState>, Condvar)>,
    circuit: Mutex<CircuitState>,
    transport: Arc<dyn BridgeTransport>,
}

impl Default for BridgeRuntime {
    fn default() -> Self {
        Self::new(Arc::new(TcpBridgeTransport))
    }
}

impl BridgeRuntime {
    pub(crate) fn new(transport: Arc<dyn BridgeTransport>) -> Self {
        Self {
            queue: Arc::new((Mutex::new(QueueState::default()), Condvar::new())),
            circuit: Mutex::new(CircuitState::default()),
            transport,
        }
    }

    pub(crate) fn request<T, R>(
        &self,
        connection_identity: u64,
        host: &str,
        port: u16,
        request: &T,
        deadline: Instant,
        control: &BridgeRequestControl,
    ) -> anyhow::Result<R>
    where
        T: BridgeRequest,
        R: DeserializeOwned,
    {
        if control.is_cancelled() {
            return Err(unavailable("request was cancelled before bridge admission"));
        }

        let started = Instant::now();
        let _permit = self.acquire(deadline, control)?;
        let queue_ms = elapsed_ms(started);
        self.begin_circuit_attempt(connection_identity)?;
        {
            let mut queue = self
                .queue
                .0
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            queue.operation = Some(ActiveOperation {
                request_id: request.request_id().to_string(),
                operation: request.operation().to_string(),
                started,
            });
        }
        let mut trace = BridgeExchangeTrace {
            stage: "serialize_request",
            ..BridgeExchangeTrace::default()
        };
        let result = (|| {
            let payload = serde_json::to_vec(request)?;
            let response = self
                .transport
                .exchange(host, port, &payload, deadline, &mut trace)?;
            trace.stage = "decode_response";
            serde_json::from_slice(response.as_slice()).map_err(anyhow::Error::from)
        })();
        let stage = trace.stage;
        let record = BridgeRequestRecord {
            request_id: request.request_id().to_string(),
            operation: request.operation().to_string(),
            queue_ms,
            total_ms: elapsed_ms(started),
            completed_at_ms: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis()
                .min(u128::from(u64::MAX)) as u64,
            success: result.is_ok(),
            exchange: trace,
        };
        self.record_request(record);
        match result {
            Ok(response) => {
                self.record_success(connection_identity);
                Ok(response)
            },
            Err(err) => {
                self.record_failure(connection_identity);
                Err(unavailable(format!(
                    "{} request {} failed at {stage} after {}ms (queue {queue_ms}ms): {err}",
                    request.operation(),
                    request.request_id(),
                    elapsed_ms(started)
                )))
            },
        }
    }

    fn record_request(&self, record: BridgeRequestRecord) {
        let mut queue = self
            .queue
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if record.success {
            if let Some(started) = queue.degraded_since.take() {
                log::info!(
                    "bridge recovered after {}ms; suppressed_failures={}",
                    elapsed_ms(started),
                    queue.suppressed_failures
                );
                queue.suppressed_failures = 0;
            }
        } else if queue.degraded_since.is_none() {
            queue.degraded_since = Some(Instant::now());
            log::warn!("bridge degraded: operation={} request_id={} stage={} queue_ms={} total_ms={} response_bytes={}",
                record.operation, record.request_id, record.exchange.stage, record.queue_ms, record.total_ms, record.exchange.response_bytes);
        } else {
            queue.suppressed_failures = queue.suppressed_failures.saturating_add(1);
        }
        if queue.recent.len() == 16 {
            queue.recent.pop_front();
        }
        queue.recent.push_back(record);
    }

    pub(crate) fn debug_info(&self) -> BridgeRuntimeDebugInfo {
        let (queue_lock, _) = &*self.queue;
        let queue = queue_lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let circuit = self
            .circuit
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let remaining = circuit
            .open_until
            .and_then(|until| until.checked_duration_since(Instant::now()))
            .unwrap_or_default();

        BridgeRuntimeDebugInfo {
            active: queue.active,
            waiting: queue.waiting,
            consecutive_failures: circuit.consecutive_failures,
            circuit_open: !remaining.is_zero(),
            circuit_remaining_ms: remaining.as_millis().min(u128::from(u64::MAX)) as u64,
            active_operation: queue
                .operation
                .as_ref()
                .map(|operation| ActiveOperationDebugInfo {
                    request_id: operation.request_id.clone(),
                    operation: operation.operation.clone(),
                    age_ms: elapsed_ms(operation.started),
                }),
            recent_requests: queue.recent.iter().cloned().collect(),
        }
    }

    fn acquire<'a>(
        &'a self,
        deadline: Instant,
        control: &BridgeRequestControl,
    ) -> anyhow::Result<BridgePermit<'a>> {
        let (lock, ready) = &*self.queue;
        let mut queue = lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if !queue.active {
            queue.active = true;
            return Ok(BridgePermit { runtime: self });
        }
        if queue.waiting >= MAX_WAITING_REQUESTS {
            return Err(unavailable("bridge request queue is full"));
        }

        queue.waiting += 1;
        loop {
            if control.is_cancelled() {
                queue.waiting -= 1;
                return Err(unavailable(
                    "request was cancelled while waiting for the bridge",
                ));
            }

            let remaining = match deadline.checked_duration_since(Instant::now()) {
                Some(remaining) if !remaining.is_zero() => remaining,
                _ => {
                    queue.waiting -= 1;
                    let active = queue
                        .operation
                        .as_ref()
                        .map(|operation| {
                            format!(
                                "; active={} request_id={} age={}ms",
                                operation.operation,
                                operation.request_id,
                                elapsed_ms(operation.started)
                            )
                        })
                        .unwrap_or_default();
                    return Err(unavailable(format!(
                        "bridge request deadline expired in the queue{active}"
                    )));
                },
            };
            let wait_for = remaining.min(CANCEL_POLL_INTERVAL);
            let (next, _) = ready
                .wait_timeout(queue, wait_for)
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            queue = next;
            if !queue.active {
                queue.waiting -= 1;
                queue.active = true;
                return Ok(BridgePermit { runtime: self });
            }
        }
    }

    fn begin_circuit_attempt(&self, identity: u64) -> anyhow::Result<()> {
        let mut circuit = self
            .circuit
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if circuit.connection_identity != Some(identity) {
            *circuit = CircuitState {
                connection_identity: Some(identity),
                ..CircuitState::default()
            };
        }

        let Some(open_until) = circuit.open_until else {
            return Ok(());
        };
        if Instant::now() < open_until {
            return Err(unavailable(
                "bridge circuit is open after repeated failures",
            ));
        }
        if circuit.half_open_active {
            return Err(unavailable("bridge recovery probe is already running"));
        }

        circuit.half_open_active = true;
        Ok(())
    }

    fn record_success(&self, identity: u64) {
        let mut circuit = self
            .circuit
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if circuit.connection_identity == Some(identity) {
            circuit.consecutive_failures = 0;
            circuit.open_until = None;
            circuit.half_open_active = false;
        }
    }

    fn record_failure(&self, identity: u64) {
        let mut circuit = self
            .circuit
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if circuit.connection_identity != Some(identity) {
            return;
        }

        circuit.half_open_active = false;
        circuit.consecutive_failures = circuit.consecutive_failures.saturating_add(1);
        if circuit.consecutive_failures >= CIRCUIT_FAILURE_THRESHOLD {
            circuit.open_until = Some(Instant::now() + CIRCUIT_COOLDOWN);
        }
    }

    fn release(&self) {
        let (lock, ready) = &*self.queue;
        let mut queue = lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        queue.active = false;
        queue.operation = None;
        ready.notify_all();
    }
}

struct BridgePermit<'a> {
    runtime: &'a BridgeRuntime,
}

impl Drop for BridgePermit<'_> {
    fn drop(&mut self) {
        self.runtime.release();
    }
}

fn remaining(deadline: Instant) -> anyhow::Result<Duration> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|remaining| !remaining.is_zero())
        .ok_or_else(|| unavailable("bridge request deadline expired"))
}

fn unavailable(message: impl Into<String>) -> anyhow::Error {
    BridgeRuntimeUnavailable {
        message: message.into(),
    }
    .into()
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::AtomicBool;
    use std::sync::atomic::AtomicUsize;
    use std::sync::atomic::Ordering;
    use std::thread;

    use serde_json::json;
    use serde_json::Value;

    use super::*;

    impl BridgeRequest for Value {
        fn request_id(&self) -> &str {
            self.get("request_id")
                .and_then(Value::as_str)
                .unwrap_or("test")
        }
        fn operation(&self) -> &str {
            self.get("command")
                .or_else(|| self.get("request"))
                .and_then(Value::as_str)
                .unwrap_or("test")
        }
    }

    #[derive(Debug, Default)]
    struct ControlledTransport {
        hits: AtomicUsize,
        fail: AtomicBool,
        blocked: Mutex<bool>,
        released: Condvar,
    }

    impl ControlledTransport {
        fn failing() -> Self {
            Self {
                fail: AtomicBool::new(true),
                ..Self::default()
            }
        }

        fn wait_for_hit(&self) {
            let started = Instant::now();
            while self.hits.load(Ordering::SeqCst) == 0 {
                assert!(
                    started.elapsed() < Duration::from_secs(1),
                    "transport was not entered"
                );
                thread::sleep(Duration::from_millis(5));
            }
        }

        fn release(&self) {
            let mut blocked = self
                .blocked
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            *blocked = false;
            self.released.notify_all();
        }
    }

    impl BridgeTransport for ControlledTransport {
        fn exchange(
            &self,
            _host: &str,
            _port: u16,
            _payload: &[u8],
            deadline: Instant,
            _trace: &mut BridgeExchangeTrace,
        ) -> anyhow::Result<Vec<u8>> {
            self.hits.fetch_add(1, Ordering::SeqCst);
            if self.fail.load(Ordering::SeqCst) {
                return Err(anyhow!("controlled transport failure"));
            }

            let mut blocked = self
                .blocked
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            while *blocked {
                let remaining = deadline
                    .checked_duration_since(Instant::now())
                    .ok_or_else(|| anyhow!("controlled transport deadline"))?;
                let (next, _) = self
                    .released
                    .wait_timeout(blocked, remaining.min(Duration::from_millis(10)))
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                blocked = next;
            }

            Ok(br#"{"ok":true}"#.to_vec())
        }
    }

    #[test]
    fn stalled_peer_reports_response_wait_not_an_opaque_os_error() {
        use std::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener");
        let port = listener.local_addr().expect("address").port();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let mut request = Vec::new();
            stream.read_to_end(&mut request).expect("read request");
            thread::sleep(Duration::from_millis(250));
        });
        let runtime = BridgeRuntime::default();
        let result: anyhow::Result<Value> = runtime.request(
            1, "127.0.0.1", port,
            &json!({"command": "view_values", "request_id": "diagnostic-test", "auth_token": "must-not-log"}),
            Instant::now() + Duration::from_millis(80), &BridgeRequestControl::default(),
        );
        let error = result.expect_err("response timeout").to_string();
        server.join().expect("server");
        assert!(
            error.contains("view_values") && error.contains("wait_first_byte"),
            "{error}"
        );
        assert!(!error.contains("must-not-log"));
        let debug = runtime.debug_info();
        assert!(debug.active_operation.is_none());
        let record = debug.recent_requests.last().expect("failure record");
        assert_eq!(record.operation, "view_values");
        assert_eq!(record.exchange.stage, "wait_first_byte");
        assert!(record.exchange.first_byte_ms.is_none());
        assert_eq!(record.exchange.response_bytes, 0);
        assert!(!serde_json::to_string(&debug)
            .expect("debug JSON")
            .contains("must-not-log"));
    }

    #[test]
    fn recent_requests_are_bounded_and_retain_only_metadata() {
        let runtime = BridgeRuntime::new(Arc::new(ControlledTransport::default()));
        for _ in 0..20 {
            let _: Value = runtime.request(1, "127.0.0.1", 1,
                &json!({"command":"view_values", "request_id":"values-test", "expr":"private data"}),
                Instant::now() + Duration::from_secs(1), &BridgeRequestControl::default()).expect("response");
        }
        let debug = runtime.debug_info();
        assert_eq!(debug.recent_requests.len(), 16);
        assert!(debug.recent_requests.iter().all(|record| record.success));
        assert!(!serde_json::to_string(&debug)
            .expect("JSON")
            .contains("private data"));
    }

    #[test]
    fn repeated_transport_failure_opens_circuit_until_identity_changes() {
        let transport = Arc::new(ControlledTransport::failing());
        let runtime = BridgeRuntime::new(transport.clone());
        let control = BridgeRequestControl::default();

        for _ in 0..4 {
            let _: anyhow::Result<Value> = runtime.request(
                1,
                "127.0.0.1",
                1,
                &json!({ "request": true }),
                Instant::now() + Duration::from_secs(1),
                &control,
            );
        }
        assert_eq!(
            transport.hits.load(Ordering::SeqCst),
            3,
            "the fourth request should be rejected by the open circuit"
        );

        transport.fail.store(false, Ordering::SeqCst);
        let response: Value = runtime
            .request(
                2,
                "127.0.0.1",
                2,
                &json!({ "request": true }),
                Instant::now() + Duration::from_secs(1),
                &control,
            )
            .expect("a new trusted connection identity should close the circuit");
        assert_eq!(response.get("ok").and_then(Value::as_bool), Some(true));
        assert_eq!(transport.hits.load(Ordering::SeqCst), 4);
    }

    #[test]
    fn healthy_probe_closes_circuit_after_cooldown() {
        let transport = Arc::new(ControlledTransport::failing());
        let runtime = BridgeRuntime::new(transport.clone());
        let control = BridgeRequestControl::default();

        for _ in 0..CIRCUIT_FAILURE_THRESHOLD {
            let _: anyhow::Result<Value> = runtime.request(
                1,
                "127.0.0.1",
                1,
                &json!({ "request": true }),
                Instant::now() + Duration::from_secs(1),
                &control,
            );
        }
        {
            let mut circuit = runtime
                .circuit
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            circuit.open_until = Some(Instant::now() - Duration::from_millis(1));
        }
        transport.fail.store(false, Ordering::SeqCst);

        let response: Value = runtime
            .request(
                1,
                "127.0.0.1",
                1,
                &json!({ "request": "recovery" }),
                Instant::now() + Duration::from_secs(1),
                &control,
            )
            .expect("a healthy half-open probe should restore the same bridge connection");

        assert_eq!(response.get("ok").and_then(Value::as_bool), Some(true));
        let debug = runtime.debug_info();
        assert_eq!(debug.consecutive_failures, 0);
        assert!(!debug.circuit_open);
    }

    #[test]
    fn cancelled_waiter_never_enters_transport() {
        let transport = Arc::new(ControlledTransport {
            blocked: Mutex::new(true),
            ..ControlledTransport::default()
        });
        let runtime = Arc::new(BridgeRuntime::new(transport.clone()));

        let first_runtime = runtime.clone();
        let first = thread::spawn(move || {
            let response: Value = first_runtime
                .request(
                    1,
                    "127.0.0.1",
                    1,
                    &json!({ "request": "first" }),
                    Instant::now() + Duration::from_secs(2),
                    &BridgeRequestControl::default(),
                )
                .expect("first request should complete after release");
            assert_eq!(response.get("ok").and_then(Value::as_bool), Some(true));
        });
        transport.wait_for_hit();
        let active = runtime
            .debug_info()
            .active_operation
            .expect("active operation");
        assert_eq!(active.operation, "first");
        let queued: anyhow::Result<Value> = runtime.request(
            1,
            "127.0.0.1",
            1,
            &json!({"command":"bootstrap"}),
            Instant::now() + Duration::from_millis(20),
            &BridgeRequestControl::default(),
        );
        assert!(queued
            .expect_err("queue timeout")
            .to_string()
            .contains("active=first"));

        let cancelled = Arc::new(AtomicBool::new(false));
        let cancel_probe = cancelled.clone();
        let second_runtime = runtime.clone();
        let second = thread::spawn(move || {
            let control = BridgeRequestControl::new(move || cancel_probe.load(Ordering::SeqCst));
            let response: anyhow::Result<Value> = second_runtime.request(
                1,
                "127.0.0.1",
                1,
                &json!({ "request": "cancelled" }),
                Instant::now() + Duration::from_secs(2),
                &control,
            );
            assert!(response.is_err(), "cancelled queued request must fail");
        });

        thread::sleep(Duration::from_millis(30));
        cancelled.store(true, Ordering::SeqCst);
        second.join().expect("cancelled waiter should finish");
        assert_eq!(
            transport.hits.load(Ordering::SeqCst),
            1,
            "cancelled queued work must not enter the bridge transport"
        );

        transport.release();
        first.join().expect("first bridge request should finish");
    }

    #[test]
    fn bridge_queue_rejects_work_beyond_bounded_capacity() {
        let transport = Arc::new(ControlledTransport {
            blocked: Mutex::new(true),
            ..ControlledTransport::default()
        });
        let runtime = Arc::new(BridgeRuntime::new(transport.clone()));
        let first_runtime = runtime.clone();
        let first = thread::spawn(move || {
            let _: Value = first_runtime
                .request(
                    1,
                    "127.0.0.1",
                    1,
                    &json!({ "request": "active" }),
                    Instant::now() + Duration::from_secs(3),
                    &BridgeRequestControl::default(),
                )
                .expect("active request should complete after release");
        });
        transport.wait_for_hit();

        let mut waiters = Vec::new();
        for index in 0..MAX_WAITING_REQUESTS {
            let runtime = runtime.clone();
            waiters.push(thread::spawn(move || {
                let _: Value = runtime
                    .request(
                        1,
                        "127.0.0.1",
                        1,
                        &json!({ "request": index }),
                        Instant::now() + Duration::from_secs(3),
                        &BridgeRequestControl::default(),
                    )
                    .expect("admitted waiter should complete after release");
            }));
        }

        let started = Instant::now();
        while runtime.debug_info().waiting != MAX_WAITING_REQUESTS {
            assert!(
                started.elapsed() < Duration::from_secs(1),
                "waiters did not fill the bounded bridge queue"
            );
            thread::sleep(Duration::from_millis(5));
        }

        let overflow: anyhow::Result<Value> = runtime.request(
            1,
            "127.0.0.1",
            1,
            &json!({ "request": "overflow" }),
            Instant::now() + Duration::from_secs(1),
            &BridgeRequestControl::default(),
        );
        assert!(overflow.is_err(), "overflow bridge work must be rejected");
        assert_eq!(
            transport.hits.load(Ordering::SeqCst),
            1,
            "overflow work must not enter transport"
        );

        transport.release();
        first.join().expect("active request should finish");
        for waiter in waiters {
            waiter.join().expect("admitted waiter should finish");
        }
    }
}
