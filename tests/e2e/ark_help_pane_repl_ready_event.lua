vim.opt.rtp:prepend(vim.fn.getcwd())

local notifications = {}
local sent_texts = {}
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

  local repl_ready = false

  lsp.start = function(_opts, bufnr)
    started_lsp = started_lsp + 1
    return bufnr
  end

  lsp.help_topic = function()
    return "dplyr::mutate", nil
  end

  lsp.sync_sessions = function()
    synced_sessions = synced_sessions + 1
  end

  tmux.start = function()
    started_pane = started_pane + 1
    return "%99", nil
  end

  tmux.status = function()
    return {
      bridge_ready = true,
      repl_ready = repl_ready,
    }
  end

  tmux.send_text = function(_config, text)
    sent_texts[#sent_texts + 1] = text
    return true, nil
  end

  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(source_buf)
  vim.api.nvim_buf_set_name(source_buf, "/tmp/ark_help_pane_repl_ready_event.R")
  vim.bo[source_buf].filetype = "r"
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "dplyr::mutate(mtcars)" })

  local original_wait = vim.wait
  vim.wait = function()
    error("ArkHelpPane REPL readiness should be event-driven, not vim.wait-based", 0)
  end
  local help_ok, help_err = pcall(function()
    return ark.help_pane(source_buf)
  end)
  vim.wait = original_wait

  if not help_ok then
    error(help_err, 0)
  end

  if #sent_texts ~= 0 then
    error("expected ArkHelpPane to wait for REPL readiness before sending help, got " .. vim.inspect(sent_texts), 0)
  end

  if type(startup_ready_callback) ~= "function" then
    error("expected ark.setup to register an LSP startup-ready callback", 0)
  end

  repl_ready = true
  startup_ready_callback(source_buf, {
    source = "test",
  })

  if
    not original_wait(1000, function()
      return #sent_texts == 1
    end, 20, false)
  then
    error("expected ArkHelpPane to send help after REPL startup-ready event, got " .. vim.inspect(sent_texts), 0)
  end

  local expected = 'utils::help("mutate", package = "dplyr", help_type = "text")'
  if sent_texts[1] ~= expected then
    error("unexpected ArkHelpPane send text: " .. vim.inspect(sent_texts), 0)
  end
  if started_lsp ~= 1 then
    error("expected ArkHelpPane to start LSP once, got " .. tostring(started_lsp), 0)
  end
  if started_pane ~= 1 then
    error("expected ArkHelpPane to start the managed pane once, got " .. tostring(started_pane), 0)
  end
  if synced_sessions ~= 1 then
    error("expected ArkHelpPane to sync sessions once, got " .. tostring(synced_sessions), 0)
  end
  if #notifications ~= 0 then
    error("expected ArkHelpPane delayed happy path to avoid notifications, got " .. vim.inspect(notifications), 0)
  end

  lsp.set_startup_ready_callback = original_set_startup_ready_callback
end)

vim.notify = original_notify

if not ok then
  error(err, 0)
end
