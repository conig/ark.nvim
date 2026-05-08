vim.opt.rtp:prepend(vim.fn.getcwd())

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.env.XDG_DATA_HOME = tmp .. "/data"

local select_calls = {}
local action_calls = {}

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
  select_calls[#select_calls + 1] = {
    items = items,
    opts = opts,
    formatted = vim.tbl_map(opts.format_item, items),
  }
  on_choice(items[1])
end

local project_root = tmp .. "/project"
vim.fn.mkdir(project_root, "p")
vim.fn.writefile({
  "targets::tar_target(clean_data, clean(raw_data))",
  "tarchetypes::tar_render(report, 'report.Rmd')",
}, project_root .. "/_targets.R")

local source_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source_buf)
vim.api.nvim_buf_set_name(source_buf, project_root .. "/_targets.R")
vim.bo[source_buf].filetype = "r"

local ark = require("ark")

local picked = nil
local ok, err = ark.targets_pick(source_buf, function(name)
  picked = name
end)
if not ok then
  error("target picker failed: " .. tostring(err), 0)
end
if picked ~= "clean_data" then
  error("expected picker to choose sorted clean_data target, got " .. vim.inspect(picked), 0)
end
if select_calls[1].opts.prompt ~= "Ark target" then
  error("unexpected target picker prompt: " .. vim.inspect(select_calls[1].opts), 0)
end
if not (select_calls[1].formatted[1] or ""):find("clean_data", 1, true) then
  error("expected picker display to include target name, got " .. vim.inspect(select_calls[1].formatted), 0)
end

local active = ark.targets_active(source_buf)
if active ~= "clean_data" then
  error("expected picked target to become active, got " .. vim.inspect(active), 0)
end

ark.targets_action_pick("load", source_buf)
if not vim.deep_equal(action_calls[1].names, { "clean_data" }) or action_calls[1].action ~= "load" then
  error("expected pick action to load clean_data, got " .. vim.inspect(action_calls), 0)
end

local active_action = ark.targets_action_active("make", source_buf)
if not active_action or not vim.deep_equal(action_calls[2].names, { "clean_data" }) or action_calls[2].action ~= "make" then
  error("expected active action to make clean_data, got " .. vim.inspect(action_calls), 0)
end

vim.ui.select = original_select
vim.fn.delete(tmp, "rf")
