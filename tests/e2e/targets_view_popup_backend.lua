vim.opt.rtp:prepend(vim.fn.getcwd())

local stopped = 0
local popup_calls = {}
local start_calls = 0

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
      view = {
        display = "tmux_popup",
        popup = {
          width = "80%",
          height = "70%",
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
    start_calls = start_calls + 1
    return nil, "target popup must not start managed pane"
  end,
  status = function()
    return { inside_tmux = true }
  end,
  stop = function() end,
  view_popup = function(_opts, server, backend_id, expr, popup_opts)
    popup_calls[#popup_calls + 1] = {
      server = server,
      backend_id = backend_id,
      expr = expr,
      popup_opts = popup_opts,
    }
    return true
  end,
}

package.loaded["ark.lsp"] = {
  set_startup_ready_callback = function() end,
  start = function() end,
  status = function()
    return {}
  end,
  sync_sessions = function() end,
}

package.loaded["ark.snippets"] = {
  open = function() end,
}

package.loaded["ark.target_view"] = {
  create = function(opts)
    return {
      expr = "targets::tar_read(name = \"" .. opts.name .. "\")",
      lsp = {
        view_open = function()
          return {
            session_id = "target-popup-test",
            title = "Target: " .. opts.name,
            schema = {},
            total_rows = 0,
            total_columns = 0,
          }
        end,
      },
      stop = function()
        stopped = stopped + 1
      end,
    }
  end,
}

local source_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source_buf)
vim.api.nvim_buf_set_name(source_buf, vim.fn.getcwd() .. "/_targets.R")
vim.bo[source_buf].filetype = "r"

local ark = require("ark")
ark.setup()

local opened, err = ark.targets_view("clean_data", source_buf)
if not opened then
  error("target popup ArkView failed: " .. tostring(err), 0)
end
if start_calls ~= 0 then
  error("target popup ArkView started managed pane " .. tostring(start_calls) .. " times", 0)
end
if #popup_calls ~= 1 then
  error("expected one tmux popup call, got " .. vim.inspect(popup_calls), 0)
end
if not popup_calls[1].expr:find("clean_data", 1, true) then
  error("expected popup expr to include target name, got " .. vim.inspect(popup_calls[1]), 0)
end

local response = require("ark.view_popup_backend").dispatch(popup_calls[1].backend_id, "view_open", {})
if type(response) ~= "table" or response.ok ~= true or response.value.session_id ~= "target-popup-test" then
  error("expected popup backend to dispatch through target-view lsp proxy, got " .. vim.inspect(response), 0)
end

require("ark.view_popup_backend").dispatch(popup_calls[1].backend_id, "dispose", {})
if stopped ~= 1 then
  error("expected popup dispose to stop target-view backend once, got " .. tostring(stopped), 0)
end

vim.print({
  targets_view_popup_backend = "ok",
})
