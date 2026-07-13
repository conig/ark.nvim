vim.opt.rtp:prepend(vim.fn.getcwd())

local local_view_calls = {}
local popup_calls = {}
local popup_error = nil
local target_stops = 0
local target_view_calls = 0

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
  assert_valid = function() end,
  defaults = function()
    return {
      async_startup = false,
      auto_start_lsp = false,
      auto_start_pane = false,
      configure_slime = false,
      filetypes = { "r" },
      lsp = {
        name = "ark_lsp",
      },
      session = {
        backend = "tmux",
      },
      view = {
        display = "auto",
        popup = {
          width = "90%",
          height = "90%",
        },
      },
    }
  end,
}

package.loaded["ark.dev"] = {
  build_detached_lsp = function()
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
    return "%ark-view-popup-routing"
  end,
  status = function()
    return {
      bridge_ready = true,
      inside_tmux = true,
      pane_exists = true,
    }
  end,
  stop = function() end,
  view_popup = function(_opts, server, backend_id, expr, popup_opts)
    popup_calls[#popup_calls + 1] = {
      server = server,
      backend_id = backend_id,
      expr = expr,
      popup_opts = popup_opts,
    }
    if popup_error then
      return nil, popup_error
    end
    return true, nil
  end,
}

package.loaded["ark.lsp"] = {
  set_startup_ready_callback = function() end,
  start = function() end,
  status = function()
    return {
      available = true,
      sessionBridgeConfigured = true,
      detachedSessionStatus = {
        lastSessionUpdateStatus = "ready",
      },
    }
  end,
  sync_sessions = function() end,
}

package.loaded["ark.snippets"] = {
  open = function() end,
}

package.loaded["ark.view"] = {
  open = function(opts)
    local_view_calls[#local_view_calls + 1] = opts
    return {
      expr = opts.expr,
      surface = "tab",
    }, nil
  end,
}

package.loaded["ark.target_view"] = {
  create = function(opts)
    return {
      expr = "targets::tar_read(name = \"" .. opts.name .. "\")",
      lsp = {},
      stop = function()
        target_stops = target_stops + 1
      end,
    }
  end,
  open = function(opts)
    target_view_calls = target_view_calls + 1
    return {
      expr = opts.name,
      surface = "tab",
    }, nil
  end,
}

local source_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source_buf)
vim.api.nvim_buf_set_name(source_buf, "/tmp/ark_view_popup_routing.R")
vim.bo[source_buf].filetype = "r"
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "mtcars" })

local ark = require("ark")
ark.setup()
dofile(vim.fs.normalize(vim.fn.getcwd() .. "/plugin/ark.lua"))

-- Regression: every ordinary ArkView entry point must honor the tmux-popup
-- presentation selected by auto mode instead of opening a scratch tab in the
-- caller's Neovim instance.
vim.cmd("ArkView mtcars")
if #popup_calls ~= 1 or popup_calls[1].expr ~= "mtcars" then
  error("expected :ArkView to use the tmux popup, got " .. vim.inspect(popup_calls), 0)
end
if #local_view_calls ~= 0 then
  error("expected :ArkView not to open an in-process tab, got " .. vim.inspect(local_view_calls), 0)
end
require("ark.view_popup_backend").dispatch(popup_calls[1].backend_id, "dispose", {})

-- Regression: once auto mode has selected the tmux popup, a launcher failure
-- must remain visible rather than silently changing ArkView to a scratch tab.
popup_error = "popup launch failed"
local opened, open_err = ark.view("iris", source_buf)
if opened ~= nil or open_err ~= popup_error then
  error("expected popup launch failure to be returned, got " .. vim.inspect({ opened = opened, err = open_err }), 0)
end
if #local_view_calls ~= 0 then
  error("popup launch failure unexpectedly fell back to an in-process tab", 0)
end
local failed_backend = require("ark.view_popup_backend").dispatch(popup_calls[2].backend_id, "view_open", {})
if
  type(failed_backend) ~= "table"
  or failed_backend.ok ~= false
  or not failed_backend.err:find("unknown ArkView popup backend", 1, true)
then
  error("failed popup backend was not unregistered: " .. vim.inspect(failed_backend), 0)
end

local target_opened, target_err = ark.targets_view("clean_data", source_buf)
if target_opened ~= nil or target_err ~= popup_error then
  error(
    "expected target ArkView popup failure to be returned, got "
      .. vim.inspect({ opened = target_opened, err = target_err }),
    0
  )
end
if target_view_calls ~= 0 then
  error("target ArkView popup failure unexpectedly fell back to an in-process tab", 0)
end
if target_stops ~= 1 then
  error("expected failed target popup backend to stop once, got " .. tostring(target_stops), 0)
end

-- Explicit tab mode remains the supported opt-out for non-popup workflows.
popup_error = nil
ark.setup({
  view = {
    display = "tab",
  },
})
local tab_opened, tab_err = ark.view("airquality", source_buf)
if not tab_opened or tab_err then
  error("explicit ArkView tab mode failed: " .. tostring(tab_err), 0)
end
if #local_view_calls ~= 1 or local_view_calls[1].expr ~= "airquality" then
  error("expected explicit tab mode to use the in-process renderer, got " .. vim.inspect(local_view_calls), 0)
end

vim.print({
  ark_view_popup_routing = "ok",
})
