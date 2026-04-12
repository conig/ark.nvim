vim.opt.rtp:prepend(vim.fn.getcwd())

local original_tmux = vim.env.TMUX
local original_system = vim.fn.system

vim.env.TMUX = "/tmp/ark-test,456,0"
_G.__ark_nvim_state = {}
package.loaded["ark.tmux"] = nil

local socket_path = "/tmp/ark.sock"
local main_session = "project"
local current_pane = "%anchor"
local next_pane = 100
local next_window = 20
local commands = {}

local panes = {
  ["%anchor"] = {
    session = main_session,
    exists = true,
  },
}

local sessions = {
  [main_session] = true,
}

local function new_pane(session_name)
  next_pane = next_pane + 1
  local pane_id = "%" .. tostring(next_pane)
  panes[pane_id] = {
    session = session_name,
    exists = true,
  }
  return pane_id
end

local function clear_commands()
  commands = {}
end

vim.fn.system = function(command)
  if type(command) ~= "table" then
    error("expected tmux invocation to use argv form, got " .. type(command), 0)
  end

  commands[#commands + 1] = vim.deepcopy(command)

  if vim.deep_equal(command, { "tmux", "display-message", "-p", "#{pane_id}" }) then
    return current_pane .. "\n"
  end

  if command[1] ~= "tmux" then
    error("unexpected command: " .. vim.inspect(command), 0)
  end

  if command[2] == "display-message" and command[3] == "-p" and command[4] == "#{TMUX_CODING_PANE_WIDTH}" then
    return "33\n"
  end

  if command[2] == "display-message" and command[3] == "-p" and command[4] == "-t" then
    local target = command[5]
    local format = command[6]
    if format == "#{pane_id}" then
      if panes[target] and panes[target].exists then
        return target .. "\n"
      end
      if sessions[target] then
        return target .. "\n"
      end
      return "missing target\n"
    end
    if format == "#{session_name}" then
      if sessions[target] then
        return target .. "\n"
      end
      return "missing session\n"
    end
    if format == "#{socket_path}\n#{session_name}" then
      local pane = panes[target]
      if pane and pane.exists then
        return socket_path .. "\n" .. pane.session .. "\n"
      end
      return "missing pane\n"
    end
    if format == "#{window_width}" then
      return "80\n"
    end
    if format == "#{window_height}" then
      return "160\n"
    end
    if format == "#{pane_width}" then
      return "80\n"
    end
    if format == "#{pane_height}" then
      return "80\n"
    end
  end

  if command[2] == "split-window" then
    local pane_id = new_pane(main_session)
    current_pane = pane_id
    return pane_id .. "\n" .. socket_path .. "\n" .. main_session .. "\n"
  end

  if command[2] == "new-window" then
    next_window = next_window + 1
    local pane_id = new_pane(main_session)
    return pane_id .. "\n@" .. tostring(next_window) .. "\n" .. socket_path .. "\n" .. main_session .. "\n"
  end

  if command[2] == "swap-pane" then
    local source
    local target
    for index = 1, #command do
      if command[index] == "-s" then
        source = command[index + 1]
      elseif command[index] == "-t" then
        target = command[index + 1]
      end
    end
    if not (panes[source] and panes[source].exists and panes[target] and panes[target].exists) then
      return "failed swap-pane\n"
    end
    local tmp_session = panes[source].session
    panes[source].session = panes[target].session
    panes[target].session = tmp_session
    current_pane = source
    return ""
  end

  if command[2] == "join-pane" then
    local source
    for index = 1, #command do
      if command[index] == "-s" then
        source = command[index + 1]
      end
    end
    if not (panes[source] and panes[source].exists) then
      return "failed join-pane\n"
    end
    panes[source].session = main_session
    current_pane = source
    return ""
  end

  if command[2] == "kill-pane" then
    local pane_id = command[4]
    if panes[pane_id] then
      panes[pane_id].exists = false
    end
    if current_pane == pane_id then
      current_pane = "%anchor"
    end
    return ""
  end

  error("unexpected tmux command: " .. vim.inspect(command), 0)
end

local ok, err = pcall(function()
  local tmux = require("ark.tmux")
  local opts = {
    configure_slime = false,
    filetypes = { "r" },
    tmux = {
      launcher = "/tmp/ark-r-launcher.sh",
      pane_layout = "auto",
      pane_percent = 33,
      stacked_pane_percent = 50,
      pane_width_env_keys = { "TMUX_CODING_PANE_WIDTH" },
      startup_status_dir = "/tmp/ark-status",
      session_pkg_path = "/tmp/arkbridge",
      session_lib_path = "/tmp/ark-lib",
      session_kind = "ark",
      session_timeout_ms = 1000,
    },
  }

  local first_pane = assert(tmux.start(opts))
  if first_pane ~= "%101" then
    error("expected first visible pane to be %101, got " .. tostring(first_pane), 0)
  end

  local split_command = nil
  for _, command in ipairs(commands) do
    if type(command) == "table" and command[2] == "split-window" then
      split_command = command
      break
    end
  end
  if not split_command or not vim.tbl_contains(split_command, "-v") or not vim.tbl_contains(split_command, "50") then
    error("expected portrait auto layout to split vertically at 50%, got " .. vim.inspect(split_command), 0)
  end

  local second_pane = assert(tmux.tab_new(opts))
  if second_pane == first_pane then
    error("expected ArkTabNew to create a distinct visible pane, got " .. tostring(second_pane), 0)
  end

  clear_commands()
  panes[second_pane].exists = false
  current_pane = "%anchor"

  local restored = assert(tmux.start(opts))
  if restored ~= first_pane then
    error("expected restore to recover the parked portrait pane, got " .. tostring(restored), 0)
  end

  local join_command = nil
  for _, command in ipairs(commands) do
    if type(command) == "table" and command[2] == "join-pane" then
      join_command = command
      break
    end
  end
  if not join_command or not vim.tbl_contains(join_command, "-v") or not vim.tbl_contains(join_command, "80") then
    error("expected portrait restore to use vertical join-pane with an 80-line slot, got " .. vim.inspect(join_command), 0)
  end
end)

vim.fn.system = original_system
vim.env.TMUX = original_tmux

if not ok then
  error(err, 0)
end
