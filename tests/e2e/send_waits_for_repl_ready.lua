vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local repl_ready = false
local start_calls = 0
local sync_calls = 0
local backend_sends = {}

package.loaded["ark"] = nil
package.loaded["ark.bridge"] = {
  ensure_current_runtime = function()
    return true
  end,
}
package.loaded["ark.lsp"] = {
  prewarm = function() end,
  set_startup_ready_callback = function() end,
  start = function() end,
  start_async = function() end,
  sync_sessions = function()
    sync_calls = sync_calls + 1
  end,
  status = function()
    return {}
  end,
}
package.loaded["ark.blink"] = {
  ensure_integration = function() end,
  handle_insert_char_pre = function() end,
  maybe_show_after_startup = function() end,
}
package.loaded["ark.tmux"] = {
  start = function()
    start_calls = start_calls + 1
    return "%77", nil
  end,
  status = function()
    return {
      bridge_ready = true,
      repl_ready = repl_ready,
    }
  end,
  send_text = function(_config, text)
    backend_sends[#backend_sends + 1] = {
      text = text,
      repl_ready = repl_ready,
    }
    return true, nil
  end,
}

local function reset_ready_after(delay_ms)
  repl_ready = false
  vim.defer_fn(function()
    repl_ready = true
  end, delay_ms)
end

local ok, err = pcall(function()
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_name(bufnr, vim.fs.normalize(ark_test.run_tmpdir() .. "/send-waits-for-repl-ready.R"))
  vim.bo[bufnr].filetype = "r"

  local ark = require("ark")
  ark.setup({
    auto_start_pane = false,
    auto_start_lsp = false,
    async_startup = false,
    configure_slime = true,
    filetypes = { "r" },
    tmux = {
      bridge_wait_ms = 1000,
    },
  })

  local delegate_sends = {}
  reset_ready_after(120)

  -- First-send user path: vim-slime calls Ark's override, which may create the
  -- managed pane. Text must not be delegated into that pane until the R prompt is ready.
  local slime_ok, slime_err = ark._slime_override_send(nil, "targets::tar_make()\n", function(config, text)
    delegate_sends[#delegate_sends + 1] = {
      config = vim.deepcopy(config),
      text = text,
      repl_ready = repl_ready,
    }
    return true, nil
  end)
  if not slime_ok then
    error("expected slime override send to succeed after repl_ready: " .. tostring(slime_err), 0)
  end

  if #delegate_sends ~= 1 then
    error("expected exactly one delegated vim-slime send, got " .. vim.inspect(delegate_sends), 0)
  end
  if delegate_sends[1].repl_ready ~= true then
    error("vim-slime send was delegated before repl_ready: " .. vim.inspect(delegate_sends), 0)
  end

  reset_ready_after(120)
  local send_ok, send_err = ark.send("print(1)")
  if not send_ok then
    error("expected ark.send() to succeed after repl_ready: " .. tostring(send_err), 0)
  end

  if #backend_sends ~= 1 then
    error("expected exactly one backend send, got " .. vim.inspect(backend_sends), 0)
  end
  if backend_sends[1].repl_ready ~= true then
    error("ark.send() reached backend before repl_ready: " .. vim.inspect(backend_sends), 0)
  end

  if start_calls ~= 2 then
    error("expected one pane start/recover attempt per send path, got " .. tostring(start_calls), 0)
  end
  if sync_calls == 0 then
    error("expected send path to schedule session sync")
  end
end)

if not ok then
  error(err, 0)
end
