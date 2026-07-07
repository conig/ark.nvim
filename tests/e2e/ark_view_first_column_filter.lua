vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local buffer_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/ark_view_first_column_filter.R")
local stop_watchdog = ark_test.start_watchdog(120000, "ark_view_first_column_filter")

local function rebuild_bridge_runtime()
  local bridge = require("ark.bridge")
  local config = require("ark.config").defaults().tmux
  local completed = nil
  local ok, build_err = bridge.build_session_runtime(config, {
    on_complete = function(result)
      completed = result
    end,
  })
  if not ok then
    error("failed to rebuild pane-side arkbridge runtime: " .. vim.inspect(build_err), 0)
  end

  local ready = vim.wait(30000, function()
    return type(completed) == "table"
  end, 50, false)
  if not ready or completed.ok ~= true then
    error("timed out rebuilding pane-side arkbridge runtime: " .. vim.inspect(completed), 0)
  end
end

local function press(keys)
  local translated = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(translated, "xt", false)
  vim.cmd("redraw")
end

local ok, err = pcall(function()
  rebuild_bridge_runtime()

  ark_test.setup_managed_buffer(buffer_path, { "" })

  local original_input = vim.ui.input
  vim.ui.input = function(opts, on_confirm)
    if not tostring(opts.prompt or ""):find("Text filter level", 1, true) then
      error("expected first-column filter prompt for level, got " .. vim.inspect(opts), 0)
    end
    on_confirm("1")
  end

  local view_state = require("ark").view(
    [[data.frame(level = c(1L, 2L, 2L), label = c("one", "two", "deux"), stringsAsFactors = FALSE)]],
    0
  )
  if type(view_state) ~= "table" then
    error("expected ArkView to open, got " .. vim.inspect(view_state), 0)
  end

  -- Regression: pressing `/` immediately after opening ArkView should filter
  -- the first data column, not the row-number gutter or a stale column.
  press("/")

  vim.ui.input = original_input

  local grid_lines = {}
  ark_test.wait_for("first-column filtered page", 5000, function()
    grid_lines = vim.api.nvim_buf_get_lines(view_state.grid_buf, 0, -1, false)
    local text = table.concat(grid_lines, "\n")
    return not text:find("loading rows", 1, true) and text:find("one", 1, true) ~= nil
  end)

  if #grid_lines ~= 3 then
    error("expected first-column filter to keep exactly one row below the typed header, got " .. vim.inspect(grid_lines), 0)
  end
  if not (grid_lines[1] or ""):find("level", 1, true) then
    error("expected grid header to include level, got " .. vim.inspect(grid_lines), 0)
  end
  if (grid_lines[3] or ""):find("(no rows)", 1, true) or not (grid_lines[3] or ""):find("1", 1, true) then
    error("expected filtered grid to keep the level=1 row, got " .. vim.inspect(grid_lines), 0)
  end

  require("ark").view_close()
end)

stop_watchdog()

if not ok then
  error(err, 0)
end
