local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local perf = require("perf")

local function monotonic_ms()
  return vim.uv.hrtime() / 1000000
end

local function percentile(sorted, p)
  if #sorted == 0 then
    return 0
  end

  local index = math.ceil(#sorted * p)
  if index < 1 then
    index = 1
  elseif index > #sorted then
    index = #sorted
  end
  return sorted[index]
end

local function summarize_timings(timings)
  table.sort(timings)
  return {
    min_ms = timings[1],
    median_ms = percentile(timings, 0.50),
    p90_ms = percentile(timings, 0.90),
    max_ms = timings[#timings],
    timings_ms = timings,
  }
end

local function ensure_bridge_runtime_current()
  local bridge = require("ark.bridge")
  local config = require("ark.config").defaults().tmux
  local completed = nil
  local ok, err = bridge.ensure_current_runtime(config, {
    on_build_complete = function(result)
      completed = result
    end,
    user_initiated = true,
  })
  if ok then
    return
  end

  if type(err) ~= "table" or err.kind ~= "build_pending" then
    ark_test.fail("failed to prepare pane-side arkbridge runtime: " .. vim.inspect(err))
  end

  local ready = vim.wait(30000, function()
    return type(completed) == "table"
  end, 50, false)
  if not ready or completed.ok ~= true then
    ark_test.fail("timed out waiting for pane-side arkbridge runtime install: " .. vim.inspect(completed or err))
  end

  local retry_ok, retry_err = bridge.ensure_current_runtime(config, {})
  if not retry_ok then
    ark_test.fail("pane-side arkbridge runtime was not current after install: " .. vim.inspect(retry_err))
  end
end

ensure_bridge_runtime_current()

local test_file = "/tmp/ark_current_env_completion_timing.R"
local pane_id, client = ark_test.setup_managed_buffer(test_file, {
  "arkenv_",
})

ark_test.tmux({
  "send-keys",
  "-t",
  pane_id,
  'rm(list = grep("^arkenv_", ls(envir = .GlobalEnv), value = TRUE), envir = .GlobalEnv); for (i in seq_len(240L)) assign(sprintf("arkenv_candidate_%03d", i), i, envir = .GlobalEnv); arkenv_callable <- function() TRUE; cat("ARK_CURRENT_ENV_COMPLETION_READY\\n")',
  "Enter",
})

ark_test.wait_for("current environment completion fixture", 10000, function()
  local capture = ark_test.tmux({ "capture-pane", "-p", "-t", pane_id })
  return capture:find("ARK_CURRENT_ENV_COMPLETION_READY", 1, true) ~= nil
end)

local params = {
  textDocument = vim.lsp.util.make_text_document_params(0),
  position = { line = 0, character = #"arkenv_" },
}

local function request_completion_sync()
  local started = monotonic_ms()
  local done = false
  local result = nil
  local request_err = nil

  local ok, err = client:request("textDocument/completion", params, function(callback_err, callback_result)
    request_err = callback_err
    result = callback_result
    done = true
  end, 0)
  if not ok then
    ark_test.fail("textDocument/completion async request failed to start: " .. tostring(err))
  end

  local completed = vim.wait(10000, function()
    return done
  end, 1, false)
  if not completed then
    ark_test.fail("timed out waiting for current environment completion response")
  end

  if request_err then
    ark_test.fail("textDocument/completion async request error: " .. vim.inspect(request_err))
  end

  local elapsed = monotonic_ms() - started
  local items = ark_test.completion_items(result)
  return elapsed, items
end

local status = require("ark").status({ include_lsp = true })
local startup_status = status and status.startup_status or nil
if type(startup_status) ~= "table" or type(startup_status.port) ~= "number" then
  ark_test.fail("current environment timing test missing bridge status: " .. vim.inspect(status))
end

local session = status.session or {}
local auth_token = startup_status.auth_token or ""

local function bridge_request(payload)
  local socket = vim.uv.new_tcp()
  if not socket then
    ark_test.fail("failed to create bridge timing socket")
  end

  payload.request_id = payload.request_id or ("ark-timing-" .. tostring(vim.uv.hrtime()))
  payload.auth_token = auth_token
  payload.session = payload.session or {
    backend = session.backend or "tmux",
    session_id = status.session_id or "",
    tmux_socket = session.tmux_socket or "",
    tmux_session = session.tmux_session or "",
    tmux_pane = session.tmux_pane or pane_id,
  }

  local chunks = {}
  local done = false
  local err_msg = nil
  local closed = false

  local function close_socket()
    if closed then
      return
    end
    closed = true
    pcall(socket.read_stop, socket)
    pcall(socket.close, socket)
  end

  local started = monotonic_ms()
  socket:connect("127.0.0.1", startup_status.port, function(connect_err)
    if connect_err then
      err_msg = tostring(connect_err)
      done = true
      close_socket()
      return
    end

    socket:read_start(function(read_err, chunk)
      if read_err then
        err_msg = tostring(read_err)
        done = true
        close_socket()
        return
      end

      if chunk then
        chunks[#chunks + 1] = chunk
        return
      end

      done = true
      close_socket()
    end)

    socket:write(vim.json.encode(payload) .. "\n", function(write_err)
      if write_err then
        err_msg = tostring(write_err)
        done = true
        close_socket()
        return
      end

      socket:shutdown(function(shutdown_err)
        if shutdown_err then
          err_msg = tostring(shutdown_err)
          done = true
          close_socket()
        end
      end)
    end)
  end)

  local completed = vim.wait(10000, function()
    return done
  end, 1, false)

  if not completed or err_msg then
    close_socket()
    ark_test.fail("bridge timing request failed: " .. tostring(err_msg or "timeout"))
  end

  local elapsed = monotonic_ms() - started
  local ok, decoded = pcall(vim.json.decode, table.concat(chunks, ""))
  if not ok or type(decoded) ~= "table" then
    ark_test.fail("bridge timing response was not JSON: " .. table.concat(chunks, ""))
  end
  if type(decoded.error) == "table" then
    ark_test.fail("bridge timing response errored: " .. vim.inspect(decoded.error))
  end

  return elapsed, decoded
end

local search_path_expr = table.concat({
  "local({ ",
  ".self <- environment(); ",
  ".ns <- tryCatch(asNamespace(\"arkbridge\"), error = function(e) NULL); ",
  ".frames <- sys.frames(); ",
  ".browser_envs <- list(); ",
  "for (.env in .frames) { ",
  "if (identical(.env, .self) || identical(.env, globalenv()) || ",
  "identical(.env, baseenv()) || identical(.env, emptyenv())) next; ",
  ".top <- topenv(.env); ",
  "if (!is.null(.ns) && identical(.top, .ns)) break; ",
  ".browser_envs[[length(.browser_envs) + 1L]] <- .env ",
  "}; ",
  "if (length(.browser_envs)) .browser_envs <- rev(.browser_envs); ",
  ".envs <- c(.browser_envs, lapply(search(), as.environment)); ",
  ".prefix <- tolower(\"arkenv_\"); ",
  ".names <- unique(unlist(lapply(.envs, function(.env) { ",
  ".x <- ls(envir = .env, all.names = TRUE); ",
  ".x[startsWith(tolower(.x), .prefix)] ",
  "}), use.names = FALSE)); ",
  ".out <- stats::setNames(vector(\"list\", length(.names)), .names); ",
  "attr(.out, \"rscope_source_class\") <- \"symbol_lookup_envs\"; ",
  "attr(.out, \"rscope_lookup_envs\") <- .envs; ",
  ".out ",
  "})",
})

local completion_payload = {
  expr = search_path_expr,
  options = {
    include_member_stats = false,
    max_members = 200,
    member_name_prefix = "arkenv_",
    request_profile = "completion_lean",
  },
}

local warmup_elapsed, warmup_items = request_completion_sync()
if not ark_test.find_item(warmup_items, "arkenv_candidate_001") then
  ark_test.fail("current environment completion missing expected variable: " .. vim.inspect({
    labels = ark_test.item_labels(warmup_items),
    elapsed_ms = warmup_elapsed,
    status = require("ark").status({ include_lsp = true }),
  }))
end

local callable = ark_test.find_item(warmup_items, "arkenv_callable")
if not callable then
  ark_test.fail("current environment completion missing callable: " .. vim.inspect(ark_test.item_labels(warmup_items)))
end

if callable.kind ~= vim.lsp.protocol.CompletionItemKind.Function then
  ark_test.fail("current environment callable returned non-function kind: " .. vim.inspect(callable))
end

local ping_timings = {}
for _ = 1, 20 do
  local elapsed = bridge_request({
    command = "ping",
  })
  ping_timings[#ping_timings + 1] = elapsed
end

local bridge_timings = {}
local bridge_item_count = 0
for _ = 1, 20 do
  local elapsed, payload = bridge_request(vim.deepcopy(completion_payload))
  bridge_timings[#bridge_timings + 1] = elapsed
  bridge_item_count = #(payload.members or {})
end

local lsp_timings = {}
local item_count = 0
for _ = 1, 20 do
  local elapsed, items = request_completion_sync()
  lsp_timings[#lsp_timings + 1] = elapsed
  item_count = #items
end

local summary = {
  item_count = item_count,
  bridge_item_count = bridge_item_count,
  ping = summarize_timings(ping_timings),
  bridge_completion = summarize_timings(bridge_timings),
  lsp_completion = summarize_timings(lsp_timings),
}

for _, elapsed in ipairs(ping_timings) do
  perf.record("completion.bridge_ping", elapsed, {
    test = "current_env_completion_timing.lua",
    condition = "warm live session",
    fixture = "240 global symbols",
  })
end
for _, elapsed in ipairs(bridge_timings) do
  perf.record("completion.bridge", elapsed, {
    test = "current_env_completion_timing.lua",
    condition = "warm live session",
    fixture = "240 global symbols",
  })
end
for _, elapsed in ipairs(lsp_timings) do
  perf.record("completion.lsp", elapsed, {
    test = "current_env_completion_timing.lua",
    condition = "warm live session",
    fixture = "240 global symbols",
  })
end

local out = vim.env.ARK_COMPLETION_TIMING_OUT
if type(out) == "string" and out ~= "" then
  vim.fn.writefile({ vim.json.encode(summary) }, out)
end

vim.print(summary)
