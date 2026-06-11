vim.opt.rtp:prepend(vim.fn.getcwd())

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.env.XDG_DATA_HOME = tmp .. "/data"

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

package.loaded["ark.snippets"] = {
  open = function() end,
}

package.loaded["ark.view"] = {
  open = function() end,
  refresh = function() end,
  close = function() end,
}

local notifications = {}
local original_notify = vim.notify
vim.notify = function(message, level, opts)
  notifications[#notifications + 1] = {
    message = message,
    level = level,
    opts = opts,
  }
end

local project_root = tmp .. "/project"
vim.fn.mkdir(project_root, "p")
local targets_file = project_root .. "/_targets.R"

vim.fn.writefile({
  "targets::tar_target(old_target_name, 1)",
}, targets_file)

vim.cmd("edit " .. vim.fn.fnameescape(targets_file))
vim.bo.filetype = "r"
local source_buf = vim.api.nvim_get_current_buf()

local ark = require("ark")

ark.targets_set_active("old_target_name", source_buf)

local active, err = ark.targets_active(source_buf)
if active ~= "old_target_name" or err ~= nil then
  error("expected initial active target old_target_name, got active=" .. vim.inspect(active) .. " err=" .. vim.inspect(err), 0)
end

-- Regression: when the active target has been renamed in the targets source
-- and saved, Ark must not keep returning the stale persisted name.
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
  "targets::tar_target(new_target_name, 1)",
})
vim.cmd("write")

active, err = ark.targets_active(source_buf)
if active == "old_target_name" then
  error("expected renamed active target to be cleared after save, got stale old_target_name", 0)
end
if active ~= nil then
  error("expected renamed active target to require reacquisition, got " .. vim.inspect(active), 0)
end
if type(err) ~= "string" or not err:find("no longer exists", 1, true) then
  error("expected stale active target error, got " .. vim.inspect(err), 0)
end

vim.notify = original_notify
vim.fn.delete(tmp, "rf")
