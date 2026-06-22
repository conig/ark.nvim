vim.opt.rtp:prepend(vim.fn.getcwd())

local notifications = {}
local view_open_exprs = {}
local started_lsp = 0
local started_pane = 0
local synced_sessions = 0
local startup_ready_callback = nil

local original_notify = vim.notify
vim.notify = function(message, level, opts)
  notifications[#notifications + 1] = {
    message = message,
    level = level,
    opts = opts,
  }
  return #notifications
end

local ok, err = pcall(function()
  local ark = require("ark")
  local lsp = require("ark.lsp")
  local tmux = require("ark.tmux")

  local original_set_startup_ready_callback = lsp.set_startup_ready_callback
  lsp.set_startup_ready_callback = function(callback)
    startup_ready_callback = callback
    return original_set_startup_ready_callback(callback)
  end

  ark.setup({
    auto_start_pane = false,
    auto_start_lsp = false,
    async_startup = false,
    configure_slime = false,
  })

  local runtime_ready = false

  lsp.start = function(_opts, bufnr)
    started_lsp = started_lsp + 1
    return bufnr
  end

  lsp.status = function()
    if not runtime_ready then
      return {
        available = false,
        sessionBridgeConfigured = false,
        detachedSessionStatus = {
          lastSessionUpdateStatus = "pending",
        },
      }
    end

    return {
      available = true,
      sessionBridgeConfigured = true,
      detachedSessionStatus = {
        lastSessionUpdateStatus = "ready",
      },
    }
  end

  lsp.sync_sessions = function()
    synced_sessions = synced_sessions + 1
  end

  lsp.view_open = function(_opts, _bufnr, expr)
    view_open_exprs[#view_open_exprs + 1] = expr
    return {
      session_id = "event-view",
      title = expr,
      total_rows = 1,
      total_columns = 1,
      schema = {
        { index = 1, name = "value", class = "numeric", type = "double" },
      },
      filters = {},
      sort = {
        column_index = 0,
        direction = "",
      },
    }, nil
  end

  lsp.view_page = function()
    return {
      offset = 0,
      limit = 200,
      total_rows = 1,
      row_numbers = { 1 },
      rows = {
        { "1" },
      },
    }, nil
  end

  tmux.start = function()
    started_pane = started_pane + 1
    return "%99", nil
  end

  tmux.status = function()
    return {
      bridge_ready = true,
      repl_ready = true,
    }
  end

  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(source_buf)
  vim.api.nvim_buf_set_name(source_buf, "/tmp/ark_view_runtime_ready_event.R")
  vim.bo[source_buf].filetype = "r"
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "mtcars" })

  local original_wait = vim.wait
  vim.wait = function()
    error("ArkView runtime readiness should be event-driven, not vim.wait-based", 0)
  end
  local view_ok, view_err = pcall(function()
    return ark.view("mtcars", source_buf)
  end)
  vim.wait = original_wait

  if not view_ok then
    error(view_err, 0)
  end

  if #view_open_exprs ~= 0 then
    error("expected ArkView to wait for runtime readiness before opening, got " .. vim.inspect(view_open_exprs), 0)
  end

  if type(startup_ready_callback) ~= "function" then
    error("expected ark.setup to register an LSP startup-ready callback", 0)
  end

  runtime_ready = true
  startup_ready_callback(source_buf, {
    source = "test",
  })

  if
    not original_wait(1000, function()
      return view_open_exprs[1] == "mtcars"
    end, 20, false)
  then
    error("expected ArkView to open after runtime startup-ready event, got " .. vim.inspect(view_open_exprs), 0)
  end

  if started_lsp ~= 1 then
    error("expected ArkView to start LSP once, got " .. tostring(started_lsp), 0)
  end
  if started_pane ~= 1 then
    error("expected ArkView to start the managed pane once, got " .. tostring(started_pane), 0)
  end
  if synced_sessions ~= 1 then
    error("expected ArkView to sync sessions once, got " .. tostring(synced_sessions), 0)
  end
  if #notifications ~= 0 then
    error("expected ArkView delayed happy path to avoid notifications, got " .. vim.inspect(notifications), 0)
  end

  lsp.set_startup_ready_callback = original_set_startup_ready_callback
end)

vim.notify = original_notify

if not ok then
  error(err, 0)
end
