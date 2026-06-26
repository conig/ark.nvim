vim.opt.rtp:prepend(vim.fn.getcwd())

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.env.XDG_DATA_HOME = tmp .. "/data"

local picker_spec = nil
local picker_closed = 0
local action_calls = {}
local async_action_started = 0
local manifest_calls = 0
local notifications = {}
local printed = {}
local view_open_calls = {}

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
    if action == "invalidate" then
      vim.wait(1200, function()
        return false
      end, 1200, false)
    end
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
  targets_action_async = function(_, _, project, action, names, callback)
    async_action_started = async_action_started + 1
    vim.defer_fn(function()
      action_calls[#action_calls + 1] = {
        project = project,
        action = action,
        names = names,
      }
      callback({ action = action, names = names, already_invalidated_names = names })
    end, 1200)
    return true
  end,
}

package.loaded["ark.snippets"] = {
  open = function() end,
}

package.loaded["ark.view"] = {
  open = function(opts)
    view_open_calls[#view_open_calls + 1] = opts
    return { expr = opts.expr }
  end,
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
vim.fn.mkdir(project_root .. "/R", "p")
vim.fn.mkdir(project_root .. "/_target_pipelines", "p")
vim.fn.writefile({
  "targets::tar_source()",
  "targets::tar_source(files = c('_target_pipelines'))",
  "targets::tar_target(clean_data, clean(raw_data))",
}, project_root .. "/_targets.R")
vim.fn.writefile({
  "targets::tar_target(default_target, make_default())",
}, project_root .. "/R/default.R")
vim.fn.writefile({
  "tarchetypes::tar_render(report, 'report.Rmd')",
}, project_root .. "/_target_pipelines/report.R")
vim.fn.mkdir(project_root .. "/_targets/meta", "p")
vim.fn.writefile({
  "name|type|parent|branches|progress",
  "clean_data|stem|||completed",
  "clean_data_group_a|stem|||completed",
  "default_target|stem|||completed",
  "report|stem|||completed",
}, project_root .. "/_targets/meta/progress")

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
local formatted_item = picker_spec.format(picker_spec.items[1])
if type(formatted_item) ~= "table" or not formatted_item[1] or formatted_item[1][2] ~= "Identifier" then
  error("expected target picker names to use Identifier highlight, got " .. vim.inspect(formatted_item), 0)
end
if type(picker_spec.items) ~= "table" or #picker_spec.items ~= 4 then
  error(
    "expected target picker items for cached clean_data, clean_data_group_a, default_target, and report, got "
      .. vim.inspect(picker_spec.items),
    0
  )
end
if type(picker_spec.items[1].preview) ~= "table" or type(picker_spec.items[1].preview.text) ~= "string" then
  error("expected target picker item to include creation preview text", 0)
end
if not picker_spec.items[1].preview.text:find("targets::tar_target%(clean_data, clean%(raw_data%)%)") then
  error("expected preview to show how clean_data was created, got " .. vim.inspect(picker_spec.items[1].preview), 0)
end
local derived_item = nil
local default_item = nil
local report_item = nil
for _, item in ipairs(picker_spec.items) do
  if item.name == "clean_data_group_a" then
    derived_item = item
  elseif item.name == "default_target" then
    default_item = item
  elseif item.name == "report" then
    report_item = item
  end
end
if type(default_item) ~= "table" or not default_item.preview.text:find("/R/default%.R:1") then
  error("expected preview to show default tar_source() location, got " .. vim.inspect(default_item and default_item.preview), 0)
end
if type(report_item) ~= "table" or not report_item.preview.text:find("_target_pipelines/report%.R:1") then
  error("expected preview to show sourced pipeline location, got " .. vim.inspect(report_item and report_item.preview), 0)
end
if type(derived_item) ~= "table" then
  error("expected target picker to include manifest-derived target clean_data_group_a", 0)
end
if not derived_item.preview.text:find("Derived from: clean_data", 1, true) then
  error("expected derived target preview to show generator provenance, got " .. vim.inspect(derived_item.preview), 0)
end
if not derived_item.preview.text:find("Progress: completed", 1, true) then
  error("expected derived target preview to show cached target progress, got " .. vim.inspect(derived_item.preview), 0)
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

local view_ok, view_err = ark.targets_view_pick(source_buf)
if not view_ok then
  error("target ArkView picker failed: " .. tostring(view_err), 0)
end
if picker_closed ~= 2 then
  error("expected target ArkView picker to close after selecting clean_data", 0)
end
if #view_open_calls ~= 1 then
  error("expected target ArkView picker to open one view, got " .. vim.inspect(view_open_calls), 0)
end
if view_open_calls[1].expr ~= 'targets::tar_read(name = "clean_data")' then
  error("expected target ArkView expression for clean_data, got " .. vim.inspect(view_open_calls[1].expr), 0)
end
if view_open_calls[1].source_bufnr ~= source_buf then
  error("expected target ArkView to use the source buffer, got " .. vim.inspect(view_open_calls[1]), 0)
end

picker_spec = nil
notifications = {}
printed = {}
local action_started = vim.loop.hrtime()
ark.targets_action_pick("invalidate", source_buf)
local action_elapsed_ms = math.floor((vim.loop.hrtime() - action_started) / 1e6)
if action_elapsed_ms >= 250 then
  error("target action picker should return before slow invalidation completes; elapsed_ms=" .. action_elapsed_ms, 0)
end
if async_action_started ~= 1 then
  error("expected target action picker to dispatch invalidate asynchronously, got " .. async_action_started, 0)
end
local action_completed = vim.wait(2500, function()
  return #action_calls >= 1 and #notifications >= 1
end, 20, false)
if not action_completed then
  error("timed out waiting for async target invalidation to finish; calls=" .. vim.inspect(action_calls), 0)
end
if not vim.deep_equal(action_calls[1].names, { "clean_data" }) or action_calls[1].action ~= "invalidate" then
  error("expected pick action to invalidate clean_data, got " .. vim.inspect(action_calls), 0)
end
if picker_closed ~= 3 then
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
