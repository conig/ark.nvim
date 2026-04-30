vim.opt.rtp:prepend(vim.fn.getcwd())

_G.__ark_nvim_state = {}
package.loaded["ark.tmux"] = nil

local original_system = vim.fn.system
local original_tmux = vim.env.TMUX

vim.env.TMUX = "/tmp/ark-test,789,0"

local socket_path = "/tmp/ark.sock"
local main_session = "project"
local current_pane = "%anchor"
local next_pane = 100
local next_window = 20
local window_width = 180
local window_height = 60
local commands = {}

local panes = {
  ["%anchor"] = {
    session = main_session,
    exists = true,
    visible = true,
    left = 0,
    top = 0,
    width = 119,
    height = window_height,
  },
  ["%right"] = {
    session = main_session,
    exists = true,
    visible = true,
    left = 120,
    top = 0,
    width = 60,
    height = window_height,
  },
}

local sessions = {
  [main_session] = true,
}

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
    left = nil,
    top = nil,
    width = nil,
    height = nil,
  }
  return pane_id
end

local function new_window_id()
  next_window = next_window + 1
  return "@" .. tostring(next_window)
end

local function normalize_tmux_command(command)
  local normalized = vim.deepcopy(command)
  if normalized[1] == "tmux" and normalized[2] == "-S" and type(normalized[3]) == "string" then
    table.remove(normalized, 2)
    table.remove(normalized, 2)
  end
  return normalized
end

local function pane_lines()
  local lines = {}
  for pane_id, pane in pairs(panes) do
    if pane.exists and pane.visible ~= false then
      lines[#lines + 1] = table.concat({
        pane_id,
        tostring(pane.left or 0),
        tostring(pane.top or 0),
        tostring(pane.width or window_width),
        tostring(pane.height or window_height),
        tostring(window_width),
        tostring(window_height),
      }, "\t")
    end
  end
  table.sort(lines)
  return table.concat(lines, "\n") .. "\n"
end

local function split_above_target(source, target, size)
  local target_pane = panes[target]
  panes[source].visible = true
  panes[source].left = target_pane.left
  panes[source].top = target_pane.top
  panes[source].width = target_pane.width
  panes[source].height = size
  target_pane.top = target_pane.top + size + 1
  target_pane.height = target_pane.height - size - 1
end

local function restore_right_slot()
  panes["%right"].visible = true
  panes["%right"].left = 120
  panes["%right"].top = 0
  panes["%right"].width = 60
  panes["%right"].height = window_height
end

local function clear_commands()
  commands = {}
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

  if normalized[2] == "display-message" and normalized[3] == "-p" and normalized[4] == "-t" then
    local target = normalized[5]
    local format = normalized[6]
    local pane = panes[target]
    if format == "#{pane_id}" then
      if pane and pane.exists then
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
      return tostring((pane and pane.width) or window_width) .. "\n"
    end
    if format == "#{pane_height}" then
      return tostring((pane and pane.height) or window_height) .. "\n"
    end
  end

  if normalized[2] == "list-panes" then
    local format = command_arg(normalized, "-F")
    if format ~= "#{pane_id}\t#{pane_left}\t#{pane_top}\t#{pane_width}\t#{pane_height}\t#{window_width}\t#{window_height}" then
      return "unexpected format\n"
    end
    return pane_lines()
  end

  if normalized[2] == "split-window" then
    local target = command_arg(normalized, "-t")
    local pct = tonumber(command_arg(normalized, "-p")) or 50
    local target_pane = panes[target]
    if not (target_pane and target_pane.exists) then
      return "failed split-window\n"
    end
    local pane_id = new_pane(main_session)
    if vim.tbl_contains(normalized, "-v") then
      local size = math.floor((target_pane.height * pct) / 100)
      if vim.tbl_contains(normalized, "-b") then
        split_above_target(pane_id, target, size)
      else
        panes[pane_id].visible = true
        panes[pane_id].left = target_pane.left
        panes[pane_id].top = target_pane.top + target_pane.height - size
        panes[pane_id].width = target_pane.width
        panes[pane_id].height = size
        target_pane.height = target_pane.height - size - 1
      end
    else
      local size = math.floor((target_pane.width * pct) / 100)
      panes[pane_id].visible = true
      panes[pane_id].left = target_pane.left + target_pane.width - size
      panes[pane_id].top = target_pane.top
      panes[pane_id].width = size
      panes[pane_id].height = target_pane.height
      target_pane.width = target_pane.width - size - 1
    end
    return pane_id .. "\n" .. socket_path .. "\n" .. main_session .. "\n"
  end

  if normalized[2] == "new-window" then
    local pane_id = new_pane(main_session)
    local window_id = new_window_id()
    return pane_id .. "\n" .. window_id .. "\n" .. socket_path .. "\n" .. main_session .. "\n"
  end

  if normalized[2] == "swap-pane" then
    local source = command_arg(normalized, "-s")
    local target = command_arg(normalized, "-t")
    if not (panes[source] and panes[source].exists and panes[target] and panes[target].exists) then
      return "failed swap-pane\n"
    end
    panes[source].visible = true
    panes[source].left = panes[target].left
    panes[source].top = panes[target].top
    panes[source].width = panes[target].width
    panes[source].height = panes[target].height
    panes[target].visible = false
    panes[target].left = nil
    panes[target].top = nil
    panes[target].width = nil
    panes[target].height = nil
    current_pane = source
    return ""
  end

  if normalized[2] == "join-pane" then
    local source = command_arg(normalized, "-s")
    local target = command_arg(normalized, "-t")
    local size = tonumber(command_arg(normalized, "-l"))
    if not (panes[source] and panes[source].exists and panes[target] and panes[target].exists and size) then
      return "failed join-pane\n"
    end
    panes[source].session = main_session
    if vim.tbl_contains(normalized, "-v") and vim.tbl_contains(normalized, "-b") then
      split_above_target(source, target, size)
    else
      panes[source].visible = true
    end
    current_pane = source
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
      stacked_pane_percent = 33,
      pane_width_env_keys = {},
      startup_status_dir = "/tmp/ark-status",
      session_pkg_path = "/tmp/arkbridge",
      session_lib_path = "/tmp/ark-lib",
      session_kind = "ark",
      session_timeout_ms = 1000,
    },
  }

  local first_pane = assert(tmux.start(opts))
  if first_pane ~= "%101" then
    error("expected first pane to be %101, got " .. tostring(first_pane), 0)
  end

  local split_command = nil
  for _, cmd in ipairs(commands) do
    if cmd[2] == "split-window" then
      split_command = cmd
      break
    end
  end
  if not split_command
    or command_arg(split_command, "-t") ~= "%right"
    or command_arg(split_command, "-p") ~= "50"
    or not vim.tbl_contains(split_command, "-v")
    or not vim.tbl_contains(split_command, "-b")
    or vim.tbl_contains(split_command, "-h")
  then
    error("expected existing right split to be reused as an upper stacked slot, got " .. vim.inspect(split_command), 0)
  end

  local second_pane = assert(tmux.tab_new(opts))
  if second_pane ~= "%102" then
    error("expected tab_new to swap hidden pane %102 into the managed slot, got " .. tostring(second_pane), 0)
  end

  clear_commands()
  panes[second_pane].exists = false
  panes[second_pane].visible = false
  restore_right_slot()
  current_pane = "%anchor"

  local restored = assert(tmux.start(opts))
  if restored ~= first_pane then
    error("expected start to restore parked pane " .. first_pane .. ", got " .. tostring(restored), 0)
  end

  local join_command = nil
  for _, cmd in ipairs(commands) do
    if cmd[2] == "join-pane" then
      join_command = cmd
      break
    end
  end
  if not join_command
    or command_arg(join_command, "-t") ~= "%right"
    or command_arg(join_command, "-l") ~= "30"
    or not vim.tbl_contains(join_command, "-v")
    or not vim.tbl_contains(join_command, "-b")
    or vim.tbl_contains(join_command, "-h")
  then
    error("expected restore to join parked pane above the existing right split, got " .. vim.inspect(join_command), 0)
  end
end)

vim.fn.system = original_system
vim.env.TMUX = original_tmux

if not ok then
  error(err, 0)
end
