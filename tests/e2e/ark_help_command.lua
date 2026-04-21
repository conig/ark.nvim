vim.opt.rtp:prepend(vim.fn.getcwd())

local notifications = {}
local started_lsp = 0
local started_pane = 0
local synced_sessions = 0
local help_requests = {}

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

  ark.setup({
    auto_start_pane = false,
    auto_start_lsp = false,
    async_startup = false,
    configure_slime = false,
  })

  local original_lsp_start = lsp.start
  local original_lsp_status = lsp.status
  local original_help_topic = lsp.help_topic
  local original_help_text = lsp.help_text
  local original_sync_sessions = lsp.sync_sessions
  local original_tmux_start = tmux.start
  local original_tmux_status = tmux.status

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

  lsp.help_topic = function(_opts, _bufnr)
    return "dplyr::mutate", nil
  end

  lsp.help_text = function(_opts, _bufnr, topic)
    help_requests[#help_requests + 1] = topic

    if topic == "dplyr::mutate" then
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
          "   ...: Name-value pairs.",
          "",
          "Examples:",
          "",
          "     mutate(mtcars, cyl2 = cyl * 2)",
          "",
          "     group_by(mtcars, cyl)",
        }, "\n"),
        references = {
          { label = "group_by()", topic = "group_by", package = "dplyr" },
        },
      }, nil
    end

    if topic == "dplyr::group_by" then
      return {
        text = table.concat({
          "group_by {dplyr}",
          "",
          "Description:",
          "",
          "     Group rows.",
        }, "\n"),
        references = {},
      }, nil
    end

    error("unexpected help text lookup for " .. vim.inspect(topic), 0)
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
      repl_ready = true,
    }
  end

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_name(buf, "/tmp/ark_help_command.R")
  vim.bo[buf].filetype = "r"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "dplyr::mutate(mtcars)" })
  vim.api.nvim_win_set_cursor(0, { 1, 10 })

  dofile(vim.fs.normalize(vim.fn.getcwd() .. "/plugin/ark.lua"))
  vim.cmd("ArkHelp")

  if started_lsp ~= 1 then
    error("expected ArkHelp to ensure ark_lsp is started once, got " .. tostring(started_lsp), 0)
  end

  if started_pane ~= 1 then
    error("expected ArkHelp to ensure the managed pane is started once, got " .. tostring(started_pane), 0)
  end

  if synced_sessions ~= 1 then
    error("expected ArkHelp to sync sessions once, got " .. tostring(synced_sessions), 0)
  end

  local help_buf = vim.api.nvim_get_current_buf()
  if help_buf == buf then
    error("expected ArkHelp to open a floating help buffer", 0)
  end

  local help_win = vim.api.nvim_get_current_win()
  local win_config = vim.api.nvim_win_get_config(help_win)
  if win_config.title and win_config.title ~= "" then
    error("expected help float to rely on in-buffer title, got window title " .. vim.inspect(win_config.title), 0)
  end

  if vim.bo[help_buf].buftype ~= "nofile" then
    error("expected help buffer to be nofile, got " .. tostring(vim.bo[help_buf].buftype), 0)
  end

  if vim.bo[help_buf].bufhidden ~= "wipe" then
    error("expected help buffer to wipe on close, got " .. tostring(vim.bo[help_buf].bufhidden), 0)
  end

  if vim.bo[help_buf].modifiable ~= false or vim.bo[help_buf].readonly ~= true then
    error("expected help buffer to be read-only, got " .. vim.inspect({
      modifiable = vim.bo[help_buf].modifiable,
      readonly = vim.bo[help_buf].readonly,
    }), 0)
  end

  local lines = vim.api.nvim_buf_get_lines(help_buf, 0, -1, false)
  if not vim.deep_equal(lines, {
    "mutate {dplyr}",
    "",
    "Description:",
    "",
    "     Modify columns. See also group_by().",
    "",
    "Usage:",
    "```r",
    "     mutate(.data, ...)",
    "```",
    "",
    "Arguments:",
    "",
    " .data: A data frame.",
    "   ...: Name-value pairs.",
    "",
    "Examples:",
    "```r",
    "     mutate(mtcars, cyl2 = cyl * 2)",
    "",
    "     group_by(mtcars, cyl)",
    "```",
  }) then
    error("unexpected help buffer contents: " .. vim.inspect(lines), 0)
  end

  if vim.bo[help_buf].filetype ~= "arkhelp" then
    error("expected help buffer to use arkhelp filetype, got " .. tostring(vim.bo[help_buf].filetype), 0)
  end

  if vim.b[help_buf].ark_help_buffer ~= true then
    error("expected help buffer marker to be set", 0)
  end

  local normal_float = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
  local usage_hl = vim.api.nvim_get_hl(0, { name = "ArkHelpUsageBody", link = false })
  if normal_float.bg and usage_hl.bg and normal_float.bg == usage_hl.bg then
    error("expected code chunk background to differ from float background", 0)
  end

  local ns = vim.api.nvim_create_namespace("ArkHelpFloat")
  local extmarks = vim.api.nvim_buf_get_extmarks(help_buf, ns, 0, -1, { details = true })
  local line_groups = {}
  local has_reference_highlight = false
  for _, mark in ipairs(extmarks) do
    if mark[4].line_hl_group then
      line_groups[mark[2] + 1] = mark[4].line_hl_group
    end
    if mark[4].hl_group == "ArkHelpReference" then
      has_reference_highlight = true
    end
  end

  if line_groups[1] ~= "ArkHelpTitle" then
    error("expected title highlight, got " .. vim.inspect(line_groups[1]), 0)
  end

  if line_groups[3] ~= "ArkHelpSectionHeader" then
    error("expected Description header highlight, got " .. vim.inspect(line_groups[3]), 0)
  end

  if line_groups[7] ~= "ArkHelpUsageHeader" then
    error("expected Usage header highlight, got " .. vim.inspect(line_groups[7]), 0)
  end

  if line_groups[12] ~= "ArkHelpArgumentsHeader" then
    error("expected Arguments header highlight, got " .. vim.inspect(line_groups[12]), 0)
  end

  if line_groups[14] ~= "ArkHelpArgumentsBody" or line_groups[15] ~= "ArkHelpArgumentsBody" then
    error("expected argument body highlights, got " .. vim.inspect({
      line_14 = line_groups[14],
      line_15 = line_groups[15],
    }), 0)
  end

  if line_groups[17] ~= "ArkHelpUsageHeader"
  then
    error("expected examples block highlights, got " .. vim.inspect({
      line_17 = line_groups[17],
    }), 0)
  end

  if line_groups[8] ~= "ArkHelpCodeFence" or line_groups[10] ~= "ArkHelpCodeFence" then
    error("expected Usage fences to use line highlights, got " .. vim.inspect({
      line_8 = line_groups[8],
      line_10 = line_groups[10],
    }), 0)
  end

  if line_groups[9] ~= "ArkHelpUsageBody" then
    error("expected Usage body to use line highlights, got " .. vim.inspect({
      line_9 = line_groups[9],
    }), 0)
  end

  if line_groups[18] ~= "ArkHelpCodeFence" or line_groups[22] ~= "ArkHelpCodeFence" then
    error("expected Examples fences to use line highlights, got " .. vim.inspect({
      line_18 = line_groups[18],
      line_22 = line_groups[22],
    }), 0)
  end

  if line_groups[19] ~= "ArkHelpUsageBody"
    or line_groups[20] ~= "ArkHelpUsageBody"
    or line_groups[21] ~= "ArkHelpUsageBody"
  then
    error("expected Examples body to use line highlights, got " .. vim.inspect({
      line_19 = line_groups[19],
      line_20 = line_groups[20],
      line_21 = line_groups[21],
    }), 0)
  end

  if not has_reference_highlight then
    error("expected at least one help reference highlight", 0)
  end

  vim.wait(120, function()
    return #vim.api.nvim_buf_get_extmarks(help_buf, ns, 0, -1, { details = true }) >= #extmarks
  end, 20, false)
  local extmarks_after_delay = vim.api.nvim_buf_get_extmarks(help_buf, ns, 0, -1, { details = true })
  if #extmarks_after_delay < #extmarks then
    error("expected ArkHelp highlights to persist after delayed redraw, got " .. tostring(#extmarks_after_delay), 0)
  end

  local reference_column = assert(lines[5]:find("group_by%(%s*%)", 1)) - 1
  vim.api.nvim_win_set_cursor(help_win, { 5, reference_column })
  vim.api.nvim_feedkeys(vim.keycode("<CR>"), "xt", false)
  vim.wait(1000, function()
    local current_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    return current_lines[1] == "group_by {dplyr}"
  end, 20, false)

  local linked_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
  if linked_lines[1] ~= "group_by {dplyr}" then
    error("expected help link follow to open group_by help, got " .. vim.inspect(linked_lines), 0)
  end

  if not vim.deep_equal(help_requests, { "dplyr::mutate", "dplyr::group_by" }) then
    error("unexpected help lookup sequence: " .. vim.inspect(help_requests), 0)
  end

  if #notifications ~= 0 then
    error("expected ArkHelp happy path to avoid notifications, got " .. vim.inspect(notifications), 0)
  end

  lsp.start = original_lsp_start
  lsp.status = original_lsp_status
  lsp.help_topic = original_help_topic
  lsp.help_text = original_help_text
  lsp.sync_sessions = original_sync_sessions
  tmux.start = original_tmux_start
  tmux.status = original_tmux_status
end)

vim.notify = original_notify

if not ok then
  error(err, 0)
end
