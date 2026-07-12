local config = require("ark.config")

local ok, errors = config.validate({
  session = { backend = "remote" },
  terminal = { split_size = 0 },
  lsp = {
    crash_recovery = {
      max_restarts = 0,
      window_ms = 0,
      base_delay_ms = 0,
      max_delay_ms = 0,
    },
  },
  typo = true,
})
assert(ok == false)
local rendered = table.concat(errors, "\n")
assert(rendered:find("config.typo", 1, true), rendered)
assert(rendered:find("config.session.backend", 1, true), rendered)
assert(rendered:find("config.terminal.split_size", 1, true), rendered)
assert(rendered:find("config.lsp.crash_recovery.max_restarts", 1, true), rendered)
assert(rendered:find("config.lsp.crash_recovery.window_ms", 1, true), rendered)
assert(rendered:find("config.lsp.crash_recovery.base_delay_ms", 1, true), rendered)
assert(rendered:find("config.lsp.crash_recovery.max_delay_ms", 1, true), rendered)
assert(rendered:find("terminal, tmux", 1, true), rendered)

local valid, valid_errors = config.validate({
  keymaps = true,
  session = { backend = "terminal", console_frontend = "nvim-console" },
  terminal = { split_direction = "vertical", split_position = "botright", split_size = 20 },
  help = { popup = { nvim = { init = "/tmp/minimal.lua" } } },
})
assert(valid == true, vim.inspect(valid_errors))

local setup_ok, setup_error = pcall(require("ark").setup, {
  session = { backend = "unsupported" },
})
assert(setup_ok == false)
assert(tostring(setup_error):find("[E_CONFIG]", 1, true), tostring(setup_error))
assert(tostring(setup_error):find("config.session.backend", 1, true), tostring(setup_error))
