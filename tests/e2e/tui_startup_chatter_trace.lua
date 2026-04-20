local log_path = vim.env.ARK_TUI_TRACE_LOG or "/tmp/ark_tui_startup_trace.log"
vim.fn.writefile({}, log_path)

local start_ms = math.floor(vim.loop.hrtime() / 1e6)

local function elapsed_ms()
  return math.floor(vim.loop.hrtime() / 1e6) - start_ms
end

local function append(value)
  value.ts_ms = elapsed_ms()
  vim.fn.writefile({ vim.json.encode(value) }, log_path, "a")
end

local function blink_state()
  local ok_blink, blink = pcall(require, "blink.cmp")
  local ok_menu, menu = pcall(require, "blink.cmp.completion.windows.menu")
  local visible = ok_blink and blink.is_visible() or false
  local menu_open = false
  if ok_menu and menu and menu.win and type(menu.win.get_win) == "function" then
    menu_open = menu.win:get_win() ~= nil
  end

  return {
    visible = visible,
    menu_open = menu_open,
  }
end

local function diagnostics_payload()
  local diagnostics = {}
  for _, diagnostic in ipairs(vim.diagnostic.get(0)) do
    diagnostics[#diagnostics + 1] = {
      message = diagnostic.message,
      lnum = diagnostic.lnum,
      col = diagnostic.col,
      severity = diagnostic.severity,
    }
  end
  return diagnostics
end

local function status_payload()
  local ok_ark, ark = pcall(require, "ark")
  if not ok_ark then
    return nil
  end

  local ok_status, status = pcall(ark.status, { include_lsp = true })
  if not ok_status or type(status) ~= "table" then
    return nil
  end

  local startup = type(status.startup) == "table" and status.startup or nil
  local lsp_status = type(status.lsp_status) == "table" and status.lsp_status or nil
  local detached = type(lsp_status) == "table" and lsp_status.detachedSessionStatus or nil

  return {
    backend = status.backend,
    bridge_ready = status.bridge_ready == true,
    repl_ready = status.repl_ready == true,
    pane_exists = status.pane_exists == true,
    named_clients = type(status.lsp_status) == "table" and status.lsp_status.clients or nil,
    startup = startup and {
      unlocked = startup.main_buffer_unlocked == true,
      source = startup.main_buffer_unlock_source,
      elapsed_ms = startup.main_buffer_unlock_elapsed_ms,
    } or nil,
    lsp = lsp_status and {
      available = lsp_status.available == true,
      sessionBridgeConfigured = lsp_status.sessionBridgeConfigured == true,
      consoleScopeCount = lsp_status.consoleScopeCount,
      libraryPathCount = lsp_status.libraryPathCount,
    } or nil,
    detached = detached and {
      lastSessionUpdateStatus = detached.lastSessionUpdateStatus,
      lastSessionUpdateMs = detached.lastSessionUpdateMs,
      lastBootstrapSuccessMs = detached.lastBootstrapSuccessMs,
      lastBootstrapDurationMs = detached.lastBootstrapDurationMs,
      lastSessionUpdateReplReady = detached.lastSessionUpdateReplReady,
    } or nil,
  }
end

local function snapshot(label, extra)
  local payload = vim.tbl_extend("force", {
    label = label,
    mode = vim.api.nvim_get_mode().mode,
    cursor = vim.api.nvim_win_get_cursor(0),
    line = vim.api.nvim_get_current_line(),
    ark_clients = #(vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" }) or {}),
    named_ark_clients = vim.tbl_map(function(client)
      return {
        id = client.id,
        initialized = client.initialized == true,
        stopped = client.is_stopped and client:is_stopped() or false,
      }
    end, vim.lsp.get_clients({ name = "ark_lsp", _uninitialized = true }) or {}),
    blink = blink_state(),
    diagnostics = diagnostics_payload(),
    status = status_payload(),
  }, extra or {})

  append(payload)
end

local function schedule_snapshot(delay_ms, label)
  vim.defer_fn(function()
    snapshot(label, {
      delay_ms = delay_ms,
    })
  end, delay_ms)
end

vim.api.nvim_create_autocmd({ "InsertEnter", "InsertLeave", "ModeChanged", "DiagnosticChanged", "LspAttach" }, {
  callback = function(args)
    snapshot(args.event, {
      match = args.match,
    })
  end,
})

vim.api.nvim_create_autocmd("User", {
  pattern = { "BlinkCmpShow", "BlinkCmpHide" },
  callback = function(args)
    snapshot(args.match, {
      user_event = args.match,
    })
  end,
})

if vim.env.ARK_TUI_TRACE_STARTINSERT == "1" then
  vim.defer_fn(function()
    snapshot("startinsert:before")
    vim.cmd("startinsert")
    snapshot("startinsert:after")
  end, 150)
end

snapshot("loaded")
for _, delay_ms in ipairs({ 100, 250, 500, 750, 1000, 1250, 1500, 2000, 3000 }) do
  schedule_snapshot(delay_ms, "tick:" .. tostring(delay_ms))
end
