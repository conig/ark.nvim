vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local fake_slime_rtp = vim.fs.normalize(ark_test.run_tmpdir() .. "/fake-slime")
local fake_slime = vim.fs.normalize(fake_slime_rtp .. "/autoload/slime.vim")

vim.fn.mkdir(vim.fs.dirname(fake_slime), "p")
vim.fn.writefile({
  "function! s:SlimeGetConfig() abort",
  "  if exists('b:slime_config')",
  "    return",
  "  endif",
  "  if exists('g:slime_default_config')",
  "    let b:slime_config = copy(g:slime_default_config)",
  "  endif",
  "  if exists('g:slime_dont_ask_default') && g:slime_dont_ask_default",
  "    return",
  "  endif",
  "endfunction",
  "",
  "function! slime#send(text) abort",
  "  call s:SlimeGetConfig()",
  "  call SlimeOverrideSend(b:slime_config, a:text)",
  "endfunction",
}, fake_slime)
vim.opt.rtp:prepend(fake_slime_rtp)

local start_calls = 0
local sends = {}

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
  sync_sessions = function() end,
}
package.loaded["ark.blink"] = {
  ensure_integration = function() end,
  handle_insert_char_pre = function() end,
  maybe_show_after_startup = function() end,
}
package.loaded["ark.tmux"] = {
  start = function()
    start_calls = start_calls + 1
    vim.g.slime_target = "tmux"
    vim.g.slime_default_config = {
      socket_name = "/tmp/ark.sock",
      target_pane = "%77",
    }
    return "%77", nil
  end,
  status = function()
    return {
      bridge_ready = true,
      repl_ready = true,
    }
  end,
  send_text = function(_config, text)
    sends[#sends + 1] = text
    return true, nil
  end,
}

local ok, err = pcall(function()
  vim.g.slime_dont_ask_default = 1
  vim.g.slime_target = nil
  vim.g.slime_default_config = nil

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_name(bufnr, vim.fs.normalize(ark_test.run_tmpdir() .. "/first-send.R"))
  vim.bo[bufnr].filetype = "r"

  local ark = require("ark")
  ark.setup({
    auto_start_pane = false,
    auto_start_lsp = false,
    async_startup = false,
    configure_slime = true,
    filetypes = { "r" },
    session = {
      backend = "tmux",
      console_frontend = "nvim-console",
    },
    tmux = {
      bridge_wait_ms = 20,
      console_frontend = "nvim-console",
    },
  })

  -- This mirrors the real user path: vim-slime must establish b:slime_config
  -- before it can dispatch to Ark's SlimeOverrideSend. On first send, Ark has
  -- not yet started the pane, so no real default config exists yet.
  vim.fn["slime#send"]("print(1)\n")

  if start_calls ~= 1 then
    error("expected Ark slime override to start the managed pane, got " .. tostring(start_calls), 0)
  end

  if #sends ~= 1 or sends[1] ~= "print(1)\n" then
    error("expected first send to reach nvim-console backend, got " .. vim.inspect(sends), 0)
  end
end)

if not ok then
  error(err, 0)
end
