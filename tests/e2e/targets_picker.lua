vim.opt.rtp:prepend(vim.fn.getcwd())

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.env.XDG_DATA_HOME = tmp .. "/data"

local picker_spec = nil
local picker_closed = 0
local action_calls = {}
local manifest_calls = 0
local notifications = {}
local printed = {}

package.loaded["snacks"] = {
  picker = {
    pick = function(spec)
      picker_spec = spec
      spec.confirm({
        close = function()
          picker_closed = picker_closed + 1
        end,
      }, spec.items[1])
    end,
  },
}

package.loaded["ark.blink"] = {
  ensure_integration = function() end,
  handle_insert_char_pre = function() end,
}

package.loaded["ark.bridge"] = {
  ensure_current_runtime = function()
    return true
  end,
  build_session_runtime = function()
    return true
  end,
}

package.loaded["ark.config"] = {
  defaults = function()
    return {
      async_startup = false,
      auto_start_lsp = false,
      auto_start_pane = false,
      filetypes = { "r" },
    }
  end,
}

package.loaded["ark.dev"] = {
  build_detached_lsp = function()
    return true
  end,
}

package.loaded["ark.session"] = {
  runtime_config = function()
    return nil
  end,
  start = function()
    return "pane"
  end,
  status = function()
    return { bridge_ready = true }
  end,
  stop = function() end,
}

package.loaded["ark.lsp"] = {
  set_startup_ready_callback = function() end,
  start = function() end,
  sync_sessions = function() end,
  status = function()
    return {
      available = true,
      sessionBridgeConfigured = true,
      detachedSessionStatus = {
        lastSessionUpdateStatus = "ready",
      },
    }
  end,
  targets_manifest = function(_, _, project)
    manifest_calls = manifest_calls + 1
    vim.wait(1200, function()
      return false
    end, 1200, false)
    return {
      project = project,
      targets = {
        { name = "report", command = "tarchetypes::tar_render(report, 'report.Rmd')" },
        { name = "clean_data", command = "clean(raw_data)" },
      },
    }
  end,
  targets_action = function(_, _, project, action, names)
    action_calls[#action_calls + 1] = {
      project = project,
      action = action,
      names = names,
    }
    if action == "invalidate" then
      return { action = action, names = names, already_invalidated_names = names }
    end
    return { action = action, names = names }
  end,
}

package.loaded["ark.snippets"] = {
  open = function() end,
}

package.loaded["ark.view"] = {
  open = function() end,
  refresh = function() end,
  close = function() end,
}

local original_select = vim.ui.select
vim.ui.select = function(items, opts, on_choice)
  on_choice(items[1])
end
local original_notify = vim.notify
vim.notify = function(message, level, opts)
  notifications[#notifications + 1] = {
    message = message,
    level = level,
    opts = opts,
  }
end
local original_print = vim.print
vim.print = function(...)
  printed[#printed + 1] = { ... }
end

local project_root = tmp .. "/project"
vim.fn.mkdir(project_root, "p")
vim.fn.mkdir(project_root .. "/_target_pipelines", "p")
vim.fn.writefile({
  "source('_target_pipelines/report.R')",
  "targets::tar_target(clean_data, clean(raw_data))",
}, project_root .. "/_targets.R")
vim.fn.writefile({
  "tarchetypes::tar_render(report, 'report.Rmd')",
}, project_root .. "/_target_pipelines/report.R")

local source_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source_buf)
vim.api.nvim_buf_set_name(source_buf, project_root .. "/_targets.R")
vim.bo[source_buf].filetype = "r"

local ark = require("ark")

local picked = nil
local started = vim.loop.hrtime()
local ok, err = ark.targets_pick(source_buf, function(name)
  picked = name
end)
local elapsed_ms = math.floor((vim.loop.hrtime() - started) / 1e6)
if not ok then
  error("target picker failed: " .. tostring(err), 0)
end
if elapsed_ms >= 1000 then
  error("target picker should list local targets in under 1s; elapsed_ms=" .. elapsed_ms, 0)
end
if manifest_calls ~= 0 then
  error("target picker should not use the bridge manifest for its initial target list", 0)
end
if picked ~= "clean_data" then
  error("expected picker to choose sorted clean_data target, got " .. vim.inspect(picked), 0)
end
if picker_closed ~= 1 then
  error("expected target picker to close after selecting clean_data", 0)
end
if picker_spec == nil then
  error("expected target picker to open a Snacks picker", 0)
end
if picker_spec.preview ~= "preview" then
  error("expected target picker to use preview panes", 0)
end
if type(picker_spec.layout) ~= "table" then
  error("expected target picker to define a Snacks layout", 0)
end
if type(picker_spec.items) ~= "table" or #picker_spec.items ~= 2 then
  error("expected target picker items for clean_data and report, got " .. vim.inspect(picker_spec.items), 0)
end
if type(picker_spec.items[1].preview) ~= "table" or type(picker_spec.items[1].preview.text) ~= "string" then
  error("expected target picker item to include creation preview text", 0)
end
if not picker_spec.items[1].preview.text:find("targets::tar_target%(clean_data, clean%(raw_data%)%)") then
  error("expected preview to show how clean_data was created, got " .. vim.inspect(picker_spec.items[1].preview), 0)
end
if not picker_spec.items[2].preview.text:find("_target_pipelines/report%.R:1") then
  error("expected preview to show sourced pipeline location, got " .. vim.inspect(picker_spec.items[2].preview), 0)
end
local layout_children = picker_spec.layout.layout or {}
local list_index = nil
local preview_index = nil
for index, child in ipairs(layout_children) do
  if child.win == "list" then
    list_index = index
  elseif child.win == "preview" then
    preview_index = index
  end
end
if not list_index or not preview_index or list_index > preview_index then
  error("expected target picker layout to put targets above the creation preview", 0)
end

local active = ark.targets_active(source_buf)
if active ~= "clean_data" then
  error("expected picked target to become active, got " .. vim.inspect(active), 0)
end

picker_spec = nil
notifications = {}
printed = {}
ark.targets_action_pick("invalidate", source_buf)
if not vim.deep_equal(action_calls[1].names, { "clean_data" }) or action_calls[1].action ~= "invalidate" then
  error("expected pick action to invalidate clean_data, got " .. vim.inspect(action_calls), 0)
end
if picker_closed ~= 2 then
  error("expected target action picker to close before invalidating clean_data", 0)
end
if #printed ~= 0 then
  error("expected target action picker to notify instead of vim.print debug output, got " .. vim.inspect(printed), 0)
end
local saw_invalidate_notice = false
for _, notification in ipairs(notifications) do
  if notification.message:find("Already invalidated target: clean_data", 1, true) then
    saw_invalidate_notice = true
  end
end
if not saw_invalidate_notice then
  error("expected user-facing already-invalidated notification, got " .. vim.inspect(notifications), 0)
end

local active_action = ark.targets_action_active("make", source_buf)
if not active_action or not vim.deep_equal(action_calls[2].names, { "clean_data" }) or action_calls[2].action ~= "make" then
  error("expected active action to make clean_data, got " .. vim.inspect(action_calls), 0)
end

vim.ui.select = original_select
vim.notify = original_notify
vim.print = original_print
vim.fn.delete(tmp, "rf")
