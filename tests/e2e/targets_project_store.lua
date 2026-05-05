vim.opt.rtp:prepend(vim.fn.getcwd())

local captured_project = nil

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
  targets_project_info = function(_, _, project)
    captured_project = project
    return { project = project }
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

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.writefile({
  "targets::tar_config_set(store = 'cache/targets')",
  "list()",
}, root .. "/_targets.R")

local source_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source_buf)
vim.api.nvim_buf_set_name(source_buf, root .. "/analysis.R")
vim.bo[source_buf].filetype = "r"

local ark = require("ark")
local result = ark.targets_project_info(source_buf)
if type(result) ~= "table" or type(captured_project) ~= "table" then
  error("target project info did not reach the LSP request", 0)
end

local expected_store = vim.fs.normalize(root .. "/cache/targets")
if captured_project.store ~= expected_store then
  error("expected custom target store " .. expected_store .. ", got " .. vim.inspect(captured_project), 0)
end
