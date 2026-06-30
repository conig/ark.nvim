vim.opt.rtp:prepend(vim.fn.getcwd())

local notifications = {}
local started_lsp = 0
local started_pane = 0
local synced_sessions = 0
local popup_calls = {}

package.loaded["ark.bridge"] = {
  ensure_current_runtime = function()
    return true
  end,
}

package.loaded["ark.session"] = {
  backend_name = function()
    return "tmux"
  end,
  runtime_config = function()
    return nil
  end,
  start = function()
    started_pane = started_pane + 1
    return "%99", nil
  end,
  status = function()
    return {
      inside_tmux = true,
      bridge_ready = true,
      repl_ready = true,
    }
  end,
  help_popup = function(_opts, text, popup_opts)
    popup_calls[#popup_calls + 1] = {
      text = text,
      opts = popup_opts,
    }
    return true, nil
  end,
  stop = function() end,
}

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

  ark.setup({
    auto_start_pane = false,
    auto_start_lsp = false,
    async_startup = false,
    configure_slime = false,
    help = {
      display = "tmux_popup",
      popup = {
        width = "88%",
        height = "77%",
      },
    },
  })

  local original_lsp_start = lsp.start
  local original_lsp_status = lsp.status
  local original_help_topic = lsp.help_topic
  local original_help_text = lsp.help_text
  local original_sync_sessions = lsp.sync_sessions

  lsp.start = function(_opts, bufnr)
    started_lsp = started_lsp + 1
    return bufnr
  end

  lsp.status = function()
    return {
      available = true,
      sessionBridgeConfigured = true,
      detachedSessionStatus = {
        lastSessionUpdateStatus = "ready",
      },
    }
  end

  lsp.help_topic = function()
    return "dplyr::mutate", nil
  end

  lsp.help_text = function(_opts, _bufnr, topic)
    if topic ~= "dplyr::mutate" then
      error("unexpected help text lookup for " .. vim.inspect(topic), 0)
    end

    return {
      text = table.concat({
        "mutate {dplyr}",
        "",
        "Description:",
        "",
        "     Modify columns. See also group_by().",
        "",
        "Usage:",
        "",
        "     mutate(.data, ...)",
        "",
        "Arguments:",
        "",
        " .data: A data frame.",
      }, "\n"),
      references = {
        { label = "group_by()", topic = "group_by", package = "dplyr" },
      },
    }, nil
  end

  lsp.sync_sessions = function()
    synced_sessions = synced_sessions + 1
  end

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, "/tmp/ark_help_tmux_popup.R")
  vim.bo[buf].filetype = "r"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "dplyr::mutate(mtcars)" })
  vim.api.nvim_win_set_cursor(0, { 1, 10 })

  dofile(vim.fs.normalize(vim.fn.getcwd() .. "/plugin/ark.lua"))
  vim.cmd("ArkHelp")

  if started_lsp ~= 1 then
    error("expected ArkHelp popup to ensure ark_lsp is started once, got " .. tostring(started_lsp), 0)
  end

  if started_pane ~= 1 then
    error("expected ArkHelp popup to ensure the managed pane is started once, got " .. tostring(started_pane), 0)
  end

  if synced_sessions ~= 1 then
    error("expected ArkHelp popup to sync sessions once, got " .. tostring(synced_sessions), 0)
  end

  if vim.api.nvim_get_current_buf() ~= buf then
    error("expected ArkHelp popup to leave the source buffer current", 0)
  end

  if #popup_calls ~= 1 then
    error("expected one ArkHelp popup call, got " .. tostring(#popup_calls), 0)
  end

  local popup = popup_calls[1]
  if not popup.text:find("mutate {dplyr}", 1, true) then
    error("expected popup text to contain help page text, got " .. vim.inspect(popup.text), 0)
  end
  if not popup.text:find("```r", 1, true) then
    error("expected popup text to preserve rendered code fences, got " .. vim.inspect(popup.text), 0)
  end
  if popup.text:find("\27%[[0-9;]*m") then
    error("expected ArkHelp Neovim popup backend to receive plain buffer text, got " .. vim.inspect(popup.text), 0)
  end

  if popup.opts.title ~= "ArkHelp: dplyr::mutate" then
    error("unexpected ArkHelp popup title: " .. vim.inspect(popup.opts), 0)
  end

  if popup.opts.width ~= "88%" or popup.opts.height ~= "77%" then
    error("unexpected ArkHelp popup size opts: " .. vim.inspect(popup.opts), 0)
  end

  if popup.opts.viewer ~= "nvim" then
    error("expected ArkHelp popup to use the Neovim backend by default, got " .. vim.inspect(popup.opts), 0)
  end

  if #notifications ~= 0 then
    error("expected ArkHelp popup happy path to avoid notifications, got " .. vim.inspect(notifications), 0)
  end

  lsp.start = original_lsp_start
  lsp.status = original_lsp_status
  lsp.help_topic = original_help_topic
  lsp.help_text = original_help_text
  lsp.sync_sessions = original_sync_sessions
end)

vim.notify = original_notify

if not ok then
  error(err, 0)
end
