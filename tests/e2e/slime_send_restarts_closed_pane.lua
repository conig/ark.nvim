vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local original_tmux = vim.env.TMUX
local original_tmux_pane = vim.env.TMUX_PANE
local original_ark_tmux_anchor_pane = vim.env.ARK_TMUX_ANCHOR_PANE
local original_ark_tmux_session = vim.env.ARK_TMUX_SESSION
local original_system = vim.fn.system

vim.env.TMUX = "/tmp/ark-test,456,0"
vim.env.TMUX_PANE = "%anchor"
vim.env.ARK_TMUX_ANCHOR_PANE = nil
vim.env.ARK_TMUX_SESSION = nil

_G.__ark_nvim_state = {}
package.loaded["ark"] = nil
package.loaded["ark.tmux"] = nil
package.loaded["ark.session_runtime"] = {
  status_file_path = function()
    return "/tmp/ark-test-status.json"
  end,
  read_status_file = function()
    return {
      status = "ready",
      port = 43077,
      auth_token = "test-token",
      repl_ready = true,
      pid = vim.fn.getpid(),
    }
  end,
  ping_bridge = function()
    return true
  end,
  status_root = function()
    return "/tmp"
  end,
  parent_server = function()
    return "/tmp/ark-parent.sock"
  end,
}
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
}

local socket_path = "/tmp/ark.sock"
local main_session = "project"
local panes = {
  ["%anchor"] = {
    exists = true,
    session = main_session,
  },
}
local next_pane = 100
local sent = {}
vim.g.ark_test_default_delegate_calls = {}

local function normalize_tmux_command(command)
  local normalized = vim.deepcopy(command)
  if normalized[1] == "tmux" and normalized[2] == "-S" and type(normalized[3]) == "string" then
    table.remove(normalized, 2)
    table.remove(normalized, 2)
  end
  return normalized
end

local function command_arg(command, flag)
  for index = 1, #command do
    if command[index] == flag then
      return command[index + 1]
    end
  end
  return nil
end

vim.fn.system = function(command)
  if type(command) ~= "table" then
    error("expected tmux invocation to use argv form, got " .. type(command), 0)
  end

  local normalized = normalize_tmux_command(command)
  if normalized[1] ~= "tmux" then
    error("unexpected command: " .. vim.inspect(normalized), 0)
  end

  if vim.deep_equal(normalized, { "tmux", "display-message", "-p", "#{pane_id}" }) then
    return "%anchor\n"
  end

  if normalized[2] == "display-message" and normalized[3] == "-p" and #normalized == 4 then
    return "\n"
  end

  if normalized[2] == "show-environment" then
    return "\n"
  end

  if normalized[2] == "display-message" and normalized[3] == "-p" and normalized[4] == "-t" then
    local target = normalized[5]
    local format = normalized[6]
    local pane = panes[target]

    if format == "#{pane_id}" then
      if pane and pane.exists then
        return target .. "\n"
      end
      return "missing pane\n"
    end

    if format == "#{socket_path}\n#{session_name}" then
      if pane and pane.exists then
        return socket_path .. "\n" .. pane.session .. "\n"
      end
      return "missing pane\n"
    end

    if format == "#{window_width}" then
      return "120\n"
    end

    if format == "#{window_height}" then
      return "40\n"
    end
  end

  if normalized[2] == "list-panes" then
    local format = command_arg(normalized, "-F")
    if format ~= "#{pane_id}\t#{pane_left}\t#{pane_top}\t#{pane_width}\t#{pane_height}\t#{window_width}\t#{window_height}" then
      error("unexpected list-panes format: " .. vim.inspect(normalized), 0)
    end

    local lines = {}
    for pane_id, pane in pairs(panes) do
      if pane.exists then
        lines[#lines + 1] = table.concat({
          pane_id,
          "0",
          "0",
          "120",
          "40",
          "120",
          "40",
        }, "\t")
      end
    end
    table.sort(lines)
    return table.concat(lines, "\n") .. "\n"
  end

  if normalized[2] == "split-window" then
    next_pane = next_pane + 1
    local pane_id = "%" .. tostring(next_pane)
    panes[pane_id] = {
      exists = true,
      session = main_session,
    }
    return pane_id .. "\n" .. socket_path .. "\n" .. main_session .. "\n"
  end

  error("unexpected tmux command: " .. vim.inspect(normalized), 0)
end

local function fake_transport_send(config, text)
  sent[#sent + 1] = {
    config = vim.deepcopy(config),
    text = text,
  }
  return true
end

-- Mirrors the user-visible vim-slime dispatch shape: direct sends use the Ark
-- override when it is installed, otherwise vim-slime sends to the current
-- buffer config as-is. This captures the closed-pane stale-target bug without
-- requiring a real tmux server or R process.
local function fake_slime_send(text)
  local ark = require("ark")
  if type(ark._slime_override_send) == "function" then
    return ark._slime_override_send(vim.b.slime_config, text)
  end
  return fake_transport_send(vim.b.slime_config, text)
end

local ok, err = pcall(function()
  local fake_slime_rtp = vim.fs.normalize(ark_test.run_tmpdir() .. "/fake-slime")
  local fake_tmux_target = fake_slime_rtp .. "/autoload/slime/targets/tmux.vim"
  vim.fn.mkdir(vim.fs.dirname(fake_tmux_target), "p")
  vim.fn.writefile({
    "function! slime#targets#tmux#send(config, text) abort",
    "  let g:ark_test_default_delegate_calls = get(g:, 'ark_test_default_delegate_calls', [])",
    "  call add(g:ark_test_default_delegate_calls, {'config': a:config, 'text': a:text})",
    "  return 1",
    "endfunction",
  }, fake_tmux_target)
  vim.opt.rtp:prepend(fake_slime_rtp)

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_buf_set_name(bufnr, vim.fs.normalize(ark_test.run_tmpdir() .. "/closed-pane-send.R"))
  vim.bo[bufnr].filetype = "r"

  local ark = require("ark")
  ark.setup({
    auto_start_pane = true,
    auto_start_lsp = false,
    async_startup = false,
    configure_slime = true,
    filetypes = { "r" },
    tmux = {
      launcher = "/tmp/ark-r-launcher.sh",
      pane_layout = "side_by_side",
      pane_percent = 33,
      startup_status_dir = "/tmp/ark-status",
      session_pkg_path = "/tmp/arkbridge",
      session_lib_path = "/tmp/ark-lib",
      session_kind = "ark",
      session_timeout_ms = 1000,
    },
  })

  if type(vim.b[bufnr].slime_config) ~= "table" or vim.b[bufnr].slime_config.target_pane ~= "%101" then
    error("expected initial Ark slime target %101, got " .. vim.inspect(vim.b[bufnr].slime_config), 0)
  end

  if vim.fn.exists("*SlimeOverrideSend") ~= 1 then
    error("expected Ark setup to install SlimeOverrideSend for vim-slime sends", 0)
  end

  local wrapper_calls = {}
  local original_override_send = _G.__ark_slime_override_send
  _G.__ark_slime_override_send = function(config, text)
    wrapper_calls[#wrapper_calls + 1] = {
      config = vim.deepcopy(config),
      text = text,
    }
    return nil
  end
  vim.fn.SlimeOverrideSend({
    socket_name = socket_path,
    target_pane = "%101",
  }, "wrapper probe\n")
  _G.__ark_slime_override_send = original_override_send

  if #wrapper_calls ~= 1 or wrapper_calls[1].text ~= "wrapper probe\n" then
    error("expected SlimeOverrideSend to call Ark Lua send override, got " .. vim.inspect(wrapper_calls), 0)
  end

  panes["%101"].exists = false

  fake_slime_send("print(1)\n")

  local calls = vim.g.ark_test_default_delegate_calls
  if type(calls) ~= "table" or #calls == 0 then
    calls = sent
  end
  local target = calls[1] and calls[1].config and calls[1].config.target_pane
  if target ~= "%102" then
    error("expected send after closed pane to target relaunched pane %102, got " .. vim.inspect(calls), 0)
  end
end)

vim.fn.system = original_system
vim.env.TMUX = original_tmux
vim.env.TMUX_PANE = original_tmux_pane
vim.env.ARK_TMUX_ANCHOR_PANE = original_ark_tmux_anchor_pane
vim.env.ARK_TMUX_SESSION = original_ark_tmux_session

if not ok then
  error(err, 0)
end
