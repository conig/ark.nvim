vim.opt.rtp:prepend(vim.fn.getcwd())

local close_calls = 0
local notifications = {}

local original_notify = vim.notify
vim.notify = function(message, level, opts)
  notifications[#notifications + 1] = {
    message = message,
    level = level,
    opts = opts,
  }
  return #notifications
end

local backend = {
  session_id = "view-grid-quit",
  schema = {
    { index = 1, name = "mpg", class = "numeric", type = "double" },
    { index = 2, name = "cyl", class = "numeric", type = "double" },
  },
  rows = {
    { "21.0", "6" },
  },
}

local function snapshot()
  return {
    session_id = backend.session_id,
    title = "mtcars",
    total_rows = #backend.rows,
    total_columns = #backend.schema,
    schema = vim.deepcopy(backend.schema),
    filters = {},
    sort = {
      column_index = 0,
      direction = "",
    },
  }
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

  lsp.start = function(_opts, bufnr)
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

  lsp.sync_sessions = function() end
  lsp.view_open = function()
    return snapshot(), nil
  end
  lsp.view_page = function(_opts, _bufnr, _session_id, offset, limit)
    return {
      offset = offset or 0,
      limit = limit or 200,
      total_rows = #backend.rows,
      row_numbers = { 1 },
      rows = vim.deepcopy(backend.rows),
    }, nil
  end
  lsp.view_close = function()
    close_calls = close_calls + 1
    return {
      closed = true,
    }, nil
  end

  tmux.start = function()
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
  vim.api.nvim_buf_set_name(source_buf, "/tmp/ark_view_grid_quit_closes_tab.R")
  vim.bo[source_buf].filetype = "r"
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "mtcars" })

  local source_tab = vim.api.nvim_get_current_tabpage()
  dofile(vim.fs.normalize(vim.fn.getcwd() .. "/plugin/ark.lua"))
  vim.cmd("ArkView mtcars")

  local view_tab = vim.api.nvim_get_current_tabpage()
  if view_tab == source_tab then
    error("expected ArkView to open a dedicated tabpage", 0)
  end

  local grid_win = nil
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(view_tab)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, 1, false)
    if (lines[1] or ""):find("mpg", 1, true) then
      grid_win = win
      break
    end
  end
  if not grid_win then
    error("expected ArkView to open a grid window", 0)
  end

  -- Regression: quitting the owner grid window with :quit must also close
  -- the companion columns pane instead of leaving it stranded in the tab.
  vim.api.nvim_set_current_win(grid_win)
  vim.cmd("quit")
  if vim.api.nvim_tabpage_is_valid(view_tab) then
    -- The E2E harness runs inside VimEnter, which suppresses non-nested
    -- WinClosed dispatch until the test body returns. Flush the owner event
    -- explicitly so this still exercises ArkView's registered close hook.
    vim.api.nvim_exec_autocmds("WinClosed", {
      pattern = tostring(grid_win),
      modeline = false,
    })
  end

  if close_calls ~= 1 then
    error("expected ArkView :quit to close its session once, got " .. tostring(close_calls), 0)
  end
  if vim.api.nvim_get_current_tabpage() ~= source_tab then
    error("expected ArkView :quit on the grid to return to the source tab", 0)
  end
  if vim.api.nvim_tabpage_is_valid(view_tab) then
    error(
      "expected ArkView :quit on the grid to close the companion column pane, remaining windows="
        .. tostring(#vim.api.nvim_tabpage_list_wins(view_tab)),
      0
    )
  end

  if notifications[1] ~= nil then
    error("expected ArkView grid quit path to avoid notifications, got " .. vim.inspect(notifications), 0)
  end
end)

vim.notify = original_notify

if not ok then
  error(err, 0)
end
