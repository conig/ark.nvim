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
local window_width = 80
local window_height = 160

local panes = {
  ["%anchor"] = {
    session = main_session,
    exists = true,
    visible = true,
    top = 0,
    width = window_width,
    height = window_height,
  },
}

local sessions = {
  [main_session] = true,
}

local function pane_size_from_percent(total, pct)
  local cells = math.floor((total * pct) / 100)
  if cells < 10 then
    return 10
  end
  if cells >= total then
    return math.max(10, total - 1)
  end
  return cells
end

local function command_arg(command, flag)
  for index = 1, #command do
    if command[index] == flag then
      return command[index + 1]
    end
  end
  return nil
end

local function new_pane(session_name)
  next_pane = next_pane + 1
  local pane_id = "%" .. tostring(next_pane)
  panes[pane_id] = {
    session = session_name,
    exists = true,
    visible = false,
    top = nil,
    width = window_width,
    height = nil,
  }
  return pane_id
end

local function clear_commands()
  commands = {}
end

local function normalize_tmux_command(command)
  local normalized = vim.deepcopy(command)
  if normalized[1] == "tmux" and normalized[2] == "-S" and type(normalized[3]) == "string" then
    table.remove(normalized, 2)
    table.remove(normalized, 2)
  end
  return normalized
end

vim.fn.system = function(command)
  if type(command) ~= "table" then
    error("expected tmux invocation to use argv form, got " .. type(command), 0)
  end

  local normalized = normalize_tmux_command(command)
  commands[#commands + 1] = normalized

  if vim.deep_equal(normalized, { "tmux", "display-message", "-p", "#{pane_id}" }) then
    return current_pane .. "\n"
  end

  if normalized[1] ~= "tmux" then
    error("unexpected command: " .. vim.inspect(normalized), 0)
  end

  if normalized[2] == "display-message" and normalized[3] == "-p" and normalized[4] == "#{TMUX_CODING_PANE_WIDTH}" then
    return "33\n"
  end

  if normalized[2] == "display-message" and normalized[3] == "-p" and normalized[4] == "-t" then
    local target = normalized[5]
    local format = normalized[6]
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
      return tostring(window_width) .. "\n"
    end
    if format == "#{window_height}" then
      return tostring(window_height) .. "\n"
    end
    if format == "#{pane_width}" then
      local pane = panes[target]
      return tostring((pane and pane.width) or window_width) .. "\n"
    end
    if format == "#{pane_height}" then
      local pane = panes[target]
      return tostring((pane and pane.height) or window_height) .. "\n"
    end
  end

  if normalized[2] == "split-window" then
    local target = command_arg(normalized, "-t")
    local target_pane = panes[target]
    local pct = tonumber(command_arg(normalized, "-p")) or 50
    local new_height = pane_size_from_percent(window_height, pct)
    local pane_id = new_pane(main_session)
    target_pane.height = window_height - new_height - 1
    target_pane.top = 0
    target_pane.visible = true
    panes[pane_id].height = new_height
    panes[pane_id].top = target_pane.height + 1
    panes[pane_id].visible = true
    return pane_id .. "\n" .. socket_path .. "\n" .. main_session .. "\n"
  end

  if normalized[2] == "new-window" then
    next_window = next_window + 1
    local pane_id = new_pane(main_session)
    return pane_id .. "\n@" .. tostring(next_window) .. "\n" .. socket_path .. "\n" .. main_session .. "\n"
  end

  if normalized[2] == "swap-pane" then
    local source
    local target
    for index = 1, #normalized do
      if normalized[index] == "-s" then
        source = normalized[index + 1]
      elseif normalized[index] == "-t" then
        target = normalized[index + 1]
      end
    end
    if not (panes[source] and panes[source].exists and panes[target] and panes[target].exists) then
      return "failed swap-pane\n"
    end
    local tmp_session = panes[source].session
    panes[source].session = panes[target].session
    panes[target].session = tmp_session
    panes[source].visible = true
    panes[source].top = panes[target].top
    panes[source].width = panes[target].width
    panes[source].height = panes[target].height
    panes[target].visible = false
    panes[target].top = nil
    panes[target].height = nil
    current_pane = source
    return ""
  end

  if normalized[2] == "join-pane" then
    local source
    local target
    local size
    for index = 1, #normalized do
      if normalized[index] == "-s" then
        source = normalized[index + 1]
      elseif normalized[index] == "-t" then
        target = normalized[index + 1]
      elseif normalized[index] == "-l" then
        size = tonumber(normalized[index + 1])
      end
    end
    if not (panes[source] and panes[source].exists and panes[target] and panes[target].exists and size) then
      return "failed join-pane\n"
    end
    panes[source].session = main_session
    panes[target].height = window_height - size - 1
    panes[target].top = 0
    panes[target].visible = true
    panes[source].visible = true
    panes[source].top = panes[target].height + 1
    panes[source].width = window_width
    panes[source].height = size
    current_pane = source
    return ""
  end

  if normalized[2] == "kill-pane" then
    local pane_id = normalized[4]
    if panes[pane_id] then
      panes["%anchor"].visible = true
      panes["%anchor"].top = 0
      panes["%anchor"].height = window_height
      panes[pane_id].exists = false
      panes[pane_id].visible = false
      panes[pane_id].top = nil
      panes[pane_id].height = nil
    end
    if current_pane == pane_id then
      current_pane = "%anchor"
    end
    return ""
  end

  error("unexpected tmux command: " .. vim.inspect(normalized), 0)
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
      stacked_pane_percent = require("ark.config").defaults().tmux.stacked_pane_percent,
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
  if not split_command or not vim.tbl_contains(split_command, "-v") or not vim.tbl_contains(split_command, "33") then
    error("expected portrait auto layout to keep the new pane in a 33% bottom slot, got " .. vim.inspect(split_command), 0)
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
  if not join_command or not vim.tbl_contains(join_command, "-v") or not vim.tbl_contains(join_command, "52") then
    error("expected portrait restore to keep the parked pane in a 52-line bottom slot, got " .. vim.inspect(join_command), 0)
  end
end)

vim.fn.system = original_system
vim.env.TMUX = original_tmux

if not ok then
  error(err, 0)
end
