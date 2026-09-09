local uv = vim.uv or vim.loop

local M = {}
local identity = require("ark.identity")

local function repo_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local ROOT = repo_root()
local DEBUG_BUILD_CMD = { "cargo", "build", "-p", "ark-lsp" }
local RELEASE_BUILD_CMD = { "cargo", "build", "-p", "ark-lsp", "--release" }
local SPINNER_FRAMES = { "[=   ]", "[==  ]", "[=== ]", "[ ===]", "[  ==]", "[   =]" }
local SOURCE_SCAN_CACHE_TTL_MS = 1000
local build_state = {
  binary_path = nil,
  command = nil,
  listeners = {},
  notify_id = nil,
  output = {},
  output_buf = nil,
  output_closed = false,
  output_win = nil,
  running = false,
  background = false,
  show_output = false,
  spinner_index = 1,
  spinner_timer = nil,
  started_at = nil,
  user_initiated = false,
}

local function rebuilds_disabled()
  return vim.env.ARK_NVIM_MANAGED_PANE == "1"
end

local function rebuild_disabled_message()
  return "ark.nvim managed panes cannot rebuild detached ark-lsp; rebuild from the parent editor"
end

local function normalize_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  return vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(path), ":p"))
end

local function monotonic_ms()
  local now = ((uv and uv.hrtime) and uv.hrtime()) or vim.loop.hrtime()
  return math.floor(now / 1e6)
end

local function stat_mtime(path)
  local stat = uv and uv.fs_stat and uv.fs_stat(path) or nil
  return stat and stat.mtime and stat.mtime.sec or nil
end

local function repo_target_binary(path)
  local origin, binary = identity.origin(path)
  return origin == "source" and binary or nil
end

local function build_spec(binary)
  local normalized = normalize_path(binary)
  local release_dir = ROOT .. "/target/release/"
  if normalized and vim.startswith(normalized, release_dir) then
    return {
      binary_path = ROOT .. "/target/release/ark-lsp",
      command = vim.deepcopy(RELEASE_BUILD_CMD),
    }
  end

  return {
    binary_path = ROOT .. "/target/debug/ark-lsp",
    command = vim.deepcopy(DEBUG_BUILD_CMD),
  }
end

-- Explicit diagnostic/test helper, never used on the editor startup path.
function M.rust_source_paths()
  local binary = ROOT .. "/target/debug/ark-lsp"
  if vim.fn.executable(binary) ~= 1 then binary = ROOT .. "/target/release/ark-lsp" end
  local result = vim.system({ binary, "--source-identity", ROOT }, { text = true }):wait()
  if result.code ~= 0 then error("ark-lsp source inventory unavailable; rebuild the local binary") end
  local paths = {}
  for _, entry in ipairs(vim.json.decode(result.stdout).inputs) do
    if uv.fs_stat(entry.path).type == "file" then paths[#paths + 1] = entry.path end
  end
  return paths
end

local function elapsed_ms()
  if not build_state.started_at then
    return nil
  end

  local now = ((uv and uv.hrtime) and uv.hrtime()) or vim.loop.hrtime()
  return math.floor((now - build_state.started_at) / 1e6)
end

local function notify(message, level, opts)
  local notify_opts = vim.tbl_extend("force", {
    title = "ark.nvim",
  }, opts or {})
  local id = vim.notify(message, level or vim.log.levels.INFO, notify_opts)
  if id ~= nil then
    build_state.notify_id = id
  end
end

local function stop_spinner()
  if build_state.spinner_timer then
    build_state.spinner_timer:stop()
    build_state.spinner_timer:close()
    build_state.spinner_timer = nil
  end
end

local function close_output_window()
  build_state.output_closed = true
  if build_state.output_win and vim.api.nvim_win_is_valid(build_state.output_win) then
    pcall(vim.api.nvim_win_close, build_state.output_win, true)
  end
  build_state.output_win = nil
end

local function current_binary_cmd(cmd, binary)
  local updated = vim.deepcopy(cmd)
  updated[1] = binary
  return updated
end

local function spinner_message()
  local frame = SPINNER_FRAMES[build_state.spinner_index] or SPINNER_FRAMES[1]
  return "Rebuilding detached ark-lsp " .. frame
end

local function start_spinner()
  notify(spinner_message(), vim.log.levels.INFO, {
    hide_from_history = true,
  })

  if not (uv and uv.new_timer) then
    return
  end

  build_state.spinner_timer = uv.new_timer()
  build_state.spinner_timer:start(120, 120, function()
    vim.schedule(function()
      if not build_state.running then
        stop_spinner()
        return
      end

      build_state.spinner_index = (build_state.spinner_index % #SPINNER_FRAMES) + 1
      notify(spinner_message(), vim.log.levels.INFO, {
        hide_from_history = true,
        replace = build_state.notify_id,
      })
    end)
  end)
end

local function ensure_output_buffer()
  if build_state.output_buf and vim.api.nvim_buf_is_valid(build_state.output_buf) then
    return build_state.output_buf
  end

  build_state.output_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[build_state.output_buf].bufhidden = "hide"
  vim.bo[build_state.output_buf].buftype = "nofile"
  vim.bo[build_state.output_buf].filetype = "log"
  vim.bo[build_state.output_buf].modifiable = true
  vim.keymap.set("n", "q", close_output_window, {
    buffer = build_state.output_buf,
    desc = "Close ark-lsp build output",
    nowait = true,
    silent = true,
  })
  if #build_state.output > 0 then
    vim.api.nvim_buf_set_lines(build_state.output_buf, 0, -1, false, build_state.output)
  end
  return build_state.output_buf
end

local function sync_output_buffer()
  if build_state.output_buf and vim.api.nvim_buf_is_valid(build_state.output_buf) then
    vim.bo[build_state.output_buf].modifiable = true
    vim.api.nvim_buf_set_lines(build_state.output_buf, 0, -1, false, build_state.output)
  end
end

local function ensure_output_window(opts)
  opts = opts or {}
  if build_state.output_closed and opts.force ~= true then
    return nil
  end

  local buf = ensure_output_buffer()
  if opts.sync ~= false then
    sync_output_buffer()
  end
  if build_state.output_win and vim.api.nvim_win_is_valid(build_state.output_win) then
    vim.api.nvim_win_set_buf(build_state.output_win, buf)
    if opts.enter ~= false then
      pcall(vim.api.nvim_set_current_win, build_state.output_win)
    end
    return build_state.output_win
  end

  local columns = math.max(20, tonumber(vim.o.columns) or 80)
  local lines = math.max(8, tonumber(vim.o.lines) or 24)
  local width = math.min(math.max(72, math.floor(columns * 0.72)), math.max(20, columns - 4))
  local height = math.min(math.max(10, math.floor(lines * 0.4)), math.max(3, lines - 4))
  build_state.output_win = vim.api.nvim_open_win(buf, opts.enter ~= false, {
    relative = "editor",
    row = math.max(1, math.floor((lines - height) / 2) - 1),
    col = math.max(1, math.floor((columns - width) / 2)),
    width = width,
    height = height,
    border = "rounded",
    style = "minimal",
    title = " ark-lsp rebuild ",
    title_pos = "center",
  })
  local win = build_state.output_win
  vim.api.nvim_create_autocmd("WinClosed", {
    once = true,
    callback = function(args)
      if tonumber(args.match) ~= win then
        return
      end
      if build_state.output_win == win then
        build_state.output_win = nil
        build_state.output_closed = true
      end
    end,
  })

  return build_state.output_win
end

local function reset_output(command)
  build_state.output = {
    "ark.nvim is rebuilding detached ark-lsp.",
    "Press q to close this window. The build continues and Ark will attach when it is ready.",
    "",
    "$ " .. table.concat(command, " "),
    "",
  }
  build_state.output_closed = false

  sync_output_buffer()
end

local function append_output_status(line)
  if type(line) ~= "string" or line == "" then
    return
  end

  build_state.output[#build_state.output + 1] = ""
  build_state.output[#build_state.output + 1] = line

  if not (build_state.output_buf and vim.api.nvim_buf_is_valid(build_state.output_buf)) then
    return
  end

  sync_output_buffer()
  if build_state.output_win and vim.api.nvim_win_is_valid(build_state.output_win) then
    local last = vim.api.nvim_buf_line_count(build_state.output_buf)
    vim.api.nvim_win_set_cursor(build_state.output_win, { last, 0 })
  end
end

local function append_output(data)
  if type(data) ~= "table" or #data == 0 then
    return
  end

  local lines = {}
  for _, line in ipairs(data) do
    if type(line) == "string" then
      lines[#lines + 1] = line
    end
  end
  if #lines == 0 then
    return
  end

  vim.list_extend(build_state.output, lines)

  if build_state.show_output ~= true or build_state.output_closed == true then
    return
  end

  local buf = ensure_output_buffer()
  if not ensure_output_window({ enter = false, sync = false }) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  if build_state.output_win and vim.api.nvim_win_is_valid(build_state.output_win) then
    local last = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(build_state.output_win, { last, 0 })
  end
end

local function finish_build(result)
  stop_spinner()
  build_state.running = false

  local listeners = build_state.listeners
  build_state.listeners = {}
  local background = build_state.background == true
  local user_initiated = build_state.user_initiated == true

  if result.ok then
    local ms = elapsed_ms()
    local suffix = ms and string.format(" in %d ms", ms) or ""
    append_output_status("detached ark-lsp rebuilt" .. suffix .. "; Ark will attach or restart the LSP for managed R buffers.")
    if not background or user_initiated then
      notify("detached ark-lsp rebuilt" .. suffix, vim.log.levels.INFO, {
        replace = build_state.notify_id,
      })
    end
    close_output_window()
  else
    append_output_status("detached ark-lsp rebuild failed; see the cargo output above.")
    if background and not user_initiated then
      notify("background detached ark-lsp rebuild failed; continuing with current binary", vim.log.levels.WARN, {
        replace = build_state.notify_id,
      })
    else
      build_state.show_output = true
      build_state.output_closed = false
      ensure_output_window({ force = true })
      notify("detached ark-lsp rebuild failed; cargo output opened in a floating window", vim.log.levels.ERROR, {
        replace = build_state.notify_id,
      })
    end
  end

  build_state.notify_id = nil
  build_state.started_at = nil
  build_state.background = false
  build_state.binary_path = nil
  build_state.command = nil
  build_state.spinner_index = 1
  build_state.user_initiated = false

  for _, listener in ipairs(listeners) do
    pcall(listener, result)
  end
end

local function start_build(opts)
  opts = opts or {}
  local spec = build_spec(opts.binary_path)

  if vim.fn.executable("cargo") ~= 1 then
    return false, "`cargo` is not available to rebuild `ark-lsp`"
  end

  if vim.fn.exists("*jobstart") ~= 1 then
    return false, "this Neovim does not support `jobstart()`, so automatic `ark-lsp` rebuild is unavailable"
  end

  if build_state.running then
    if build_state.binary_path ~= spec.binary_path then
      return false, string.format(
        "ark-lsp rebuild already targets %s; cannot also build %s",
        tostring(build_state.binary_path),
        spec.binary_path
      )
    end
    if opts and opts.on_complete then
      build_state.listeners[#build_state.listeners + 1] = opts.on_complete
    end
    if opts and opts.background ~= true then
      build_state.background = false
    end
    if opts and opts.user_initiated == true then
      build_state.user_initiated = true
    end
    if opts and opts.show_output ~= false then
      build_state.show_output = true
      build_state.output_closed = false
      ensure_output_window({
        enter = opts.focus_output ~= false,
        force = true,
      })
    end
    if not build_state.background and build_state.show_output ~= true and not build_state.spinner_timer then
      start_spinner()
    end
    return true, nil
  end

  build_state.running = true
  build_state.binary_path = spec.binary_path
  build_state.command = spec.command
  build_state.background = opts and opts.background == true or false
  build_state.show_output = not (opts and opts.show_output == false)
  build_state.listeners = {}
  if opts and opts.on_complete then
    build_state.listeners[#build_state.listeners + 1] = opts.on_complete
  end
  build_state.started_at = ((uv and uv.hrtime) and uv.hrtime()) or vim.loop.hrtime()
  build_state.spinner_index = 1
  build_state.user_initiated = opts and opts.user_initiated == true or false
  reset_output(spec.command)
  if build_state.show_output then
    ensure_output_window({
      enter = not (opts and opts.focus_output == false),
    })
  end
  if not build_state.background and build_state.show_output ~= true then
    start_spinner()
  end

  local buffer_output = build_state.background and build_state.show_output ~= true
  local job_id = vim.fn.jobstart(spec.command, {
    cwd = ROOT,
    env = { CARGO_TARGET_DIR = ROOT .. "/target" },
    -- Hidden background builds must not stream Cargo's repeated lock-wait
    -- chatter through Neovim's event loop. Buffering keeps the editor idle
    -- while retaining the complete output for failure reporting at exit.
    stdout_buffered = buffer_output,
    stderr_buffered = buffer_output,
    on_stdout = function(_, data)
      vim.schedule(function()
        append_output(data)
      end)
    end,
    on_stderr = function(_, data)
      vim.schedule(function()
        append_output(data)
      end)
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local path = spec.binary_path
        if code == 0 and stat_mtime(path) then
          finish_build({
            ok = true,
            binary_path = path,
          })
          return
        end

        local output = vim.trim(table.concat(build_state.output, "\n"))
        if output == "" then
          output = "cargo build failed"
        end
        finish_build({
          ok = false,
          error = output,
        })
      end)
    end,
  })

  if job_id <= 0 then
    build_state.running = false
    stop_spinner()
    build_state.background = false
    build_state.binary_path = nil
    build_state.command = nil
    build_state.notify_id = nil
    build_state.started_at = nil
    build_state.user_initiated = false
    return false, "failed to start cargo build for detached ark-lsp"
  end

  return true, nil
end

local function schedule_when_idle(callback)
  if uv and uv.new_idle then
    local idle = uv.new_idle()
    idle:start(function()
      idle:stop()
      idle:close()
      vim.schedule(callback)
    end)
    return
  end

  vim.api.nvim_create_autocmd("SafeState", {
    once = true,
    callback = callback,
    desc = "Check detached ark-lsp freshness after startup becomes idle",
  })
end

local reconcile_states = {}

local function reconcile(binary, opts)
  if rebuilds_disabled() then return end
  local state = reconcile_states[binary] or { listeners = {}, checked_ms = 0 }
  reconcile_states[binary] = state
  -- One callback per buffer/config request; consume them on every completed check.
  if opts.on_build_complete then state.listeners[opts.on_build_complete] = true end
  if state.running then return end
  if state.binary_signature == identity.binary_signature(binary)
    and (not opts.force_check or state.failed)
    and monotonic_ms() - state.checked_ms < (state.failed and 30000 or SOURCE_SCAN_CACHE_TTL_MS) then
    state.listeners = {}
    return
  end
  state.running = true
  schedule_when_idle(function()
    identity.check_plugin(binary)
    identity.state(binary, { phase = "checking" })
    identity.snapshot(binary, "lsp", function(snapshot, err)
      local function finish(result)
        state.running = false
        state.failed = result and result.ok == false
        state.checked_ms = monotonic_ms()
        state.binary_signature = identity.binary_signature(binary)
        local listeners = state.listeners
        state.listeners = {}
        if result then for listener in pairs(listeners) do pcall(listener, result) end end
      end
      if snapshot and snapshot.fingerprint == snapshot.built.source_fingerprint
        and snapshot.built.profile == (binary:find("/release/", 1, true) and "release" or "debug") then
        local previous = identity.state(binary)
        identity.state(binary, { expected = snapshot.fingerprint, expected_build_id = snapshot.built.build_id, installed = snapshot.built,
          phase = previous.running and previous.running.source_fingerprint == snapshot.fingerprint
            and previous.running.build_id == snapshot.built.build_id and "current" or "available" })
        -- A build performed outside this editor must replace a still-running old process too.
        finish((previous.expected ~= snapshot.fingerprint or previous.expected_build_id ~= snapshot.built.build_id)
          and { ok = true, binary_path = binary } or nil)
        return
      end
      identity.state(binary, { phase = "updating", error = err or false })
      notify("Updating Ark LSP…", vim.log.levels.INFO)
      local started, build_err = start_build({
        binary_path = binary, background = true, show_output = false,
        on_complete = function(result)
          if not result.ok then
            identity.state(binary, { phase = "failed", error = result.error })
            finish(result)
            return
          end
          identity.snapshot(binary, "lsp", function(updated, verify_err)
            if not updated or updated.fingerprint ~= updated.built.source_fingerprint
              or updated.built.profile ~= (binary:find("/release/", 1, true) and "release" or "debug") then
              local message = verify_err or "sources changed during the build; check again after editing finishes"
              identity.state(binary, { phase = "failed", error = message })
              notify("Ark update could not be verified: " .. message, vim.log.levels.ERROR)
              finish({ ok = false, error = message })
              return
            end
            identity.state(binary, { phase = "restarting", expected = updated.fingerprint, expected_build_id = updated.built.build_id,
              installed = updated.built, announce_activation = true })
            finish(result)
          end, true)
        end,
      })
      if not started then
        identity.state(binary, { phase = "failed", error = build_err })
        notify("Ark update failed; older binary remains active: " .. tostring(build_err), vim.log.levels.ERROR)
        finish({ ok = false, error = build_err })
      end
    end)
  end)
end

function M.ensure_current_detached_lsp_cmd(cmd, opts)
  opts = opts or {}

  if type(cmd) ~= "table" or type(cmd[1]) ~= "string" or cmd[1] == "" then
    return cmd, nil
  end

  local origin, owned_binary = identity.origin(cmd[1])
  if origin == "source" then
    if rebuilds_disabled() and not stat_mtime(owned_binary) then return nil, rebuild_disabled_message() end
    reconcile(owned_binary, opts)
    if not stat_mtime(owned_binary) then
      return nil, { kind = "build_pending", message = "Updating Ark LSP…" }
    end
    return current_binary_cmd(cmd, owned_binary), nil
  end
  if not rebuilds_disabled() then
    schedule_when_idle(function() identity.verify_external(cmd[1], opts.on_build_complete) end)
  end
  return cmd, nil
end

function M.detached_lsp_build_fingerprint(path)
  if type(path) ~= "string" or path == "" then return nil end
  local resolved = vim.fn.exepath(path)
  if resolved == "" then resolved = normalize_path(path) end
  if not resolved or not stat_mtime(resolved) then return nil end
  return resolved .. "::" .. identity.binary_signature(resolved)
end

function M.build_detached_lsp(opts)
  opts = opts or {}
  if rebuilds_disabled() then
    return false, rebuild_disabled_message()
  end

  if opts.binary_path and not repo_target_binary(opts.binary_path) then
    return false, "the selected external Ark binary is not owned by this checkout; it will not be overwritten"
  end
  return start_build({
    binary_path = opts.binary_path,
    on_complete = opts.on_complete,
    show_output = opts.show_output ~= false,
    user_initiated = true,
  })
end

return M
