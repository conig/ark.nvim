vim.opt.rtp:prepend(vim.fn.getcwd())

_G.__ark_nvim_state = {}
package.loaded["ark.tmux"] = nil

local original_system = vim.fn.system

local socket_path = "/tmp/ark.sock"
local main_session = "project"
local current_pane = "%anchor"
local next_pane = 100
local next_window = 20
local parking_session = nil
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

local function trim_colon(value)
  return (value or ""):gsub(":$", "")
end

local function new_pane(session_name)
  next_pane = next_pane + 1
  local pane_id = "%" .. tostring(next_pane)
  panes[pane_id] = {
    session = session_name,
    exists = true,
  }
  return pane_id
end

local function new_window_id()
  next_window = next_window + 1
  return "@" .. tostring(next_window)
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
      return "180\n"
    end
    if format == "#{pane_width}" then
      return "60\n"
    end
  end

  if command[2] == "split-window" then
    local pane_id = new_pane(main_session)
    return pane_id .. "\n"
  end

  if command[2] == "new-session" then
    local session_name
    for index = 1, #command do
      if command[index] == "-s" then
        session_name = command[index + 1]
      end
    end
    sessions[session_name] = true
    parking_session = session_name
    local keepalive_pane = new_pane(session_name)
    panes[keepalive_pane].keepalive = true
    return session_name .. "\n"
  end

  if command[2] == "break-pane" then
    local source
    local target
    for index = 1, #command do
      if command[index] == "-s" then
        source = command[index + 1]
      elseif command[index] == "-t" then
        target = trim_colon(command[index + 1])
      end
    end
    if not (panes[source] and panes[source].exists and sessions[target]) then
      return "failed break-pane\n"
    end
    panes[source].session = target
    local window_id = new_window_id()
    return window_id .. "\n"
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
    return ""
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
    return ""
  end

  if command[2] == "kill-pane" then
    local pane_id = command[4]
    if panes[pane_id] then
      panes[pane_id].exists = false
    end
    return ""
  end

  if command[2] == "kill-session" then
    local session_name = command[4]
    sessions[session_name] = nil
    parking_session = nil
    for _, pane in pairs(panes) do
      if pane.session == session_name and pane.keepalive == true then
        pane.exists = false
      end
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
      pane_percent = 33,
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
    error("expected first visible pane to be %101, got " .. tostring(first_pane), 0)
  end

  local second_pane = assert(tmux.tab_new(opts))
  if second_pane == first_pane then
    error("expected ArkTabNew to create a distinct visible pane, got " .. tostring(second_pane), 0)
  end

  local status_after_new = tmux.status(opts.tmux)
  if status_after_new.tab_count ~= 2 then
    error("expected two tabs after ArkTabNew, got " .. vim.inspect(status_after_new), 0)
  end
  if status_after_new.active_index ~= 2 then
    error("expected second tab to be active after ArkTabNew, got " .. vim.inspect(status_after_new), 0)
  end
  if not parking_session or status_after_new.parking_session_name ~= parking_session then
    error("expected parking session to exist, got " .. vim.inspect(status_after_new), 0)
  end
  if status_after_new.tabs[1].visible ~= false then
    error("expected first tab to be parked, got " .. vim.inspect(status_after_new.tabs), 0)
  end
  if status_after_new.tabs[1].session.tmux_session ~= main_session then
    error("expected parked tab to retain startup session metadata, got " .. vim.inspect(status_after_new.tabs[1]), 0)
  end

  local restored = assert(tmux.tab_prev(opts))
  if restored ~= first_pane then
    error("expected ArkTabPrev to restore " .. first_pane .. ", got " .. tostring(restored), 0)
  end
  local saw_swap = false
  local saw_join = false
  for _, command in ipairs(commands) do
    if type(command) == "table" and command[2] == "swap-pane" then
      saw_swap = true
    end
    if type(command) == "table" and command[2] == "join-pane" then
      saw_join = true
    end
  end
  if not saw_swap then
    error("expected Ark tab switching to use tmux swap-pane, got commands: " .. vim.inspect(commands), 0)
  end
  if saw_join then
    error("expected Ark tab switching to avoid tmux join-pane redraws, got commands: " .. vim.inspect(commands), 0)
  end

  local status_after_prev = tmux.status(opts.tmux)
  if status_after_prev.active_index ~= 1 or status_after_prev.pane_id ~= "%101" then
    error("expected first tab to be active after ArkTabPrev, got " .. vim.inspect(status_after_prev), 0)
  end
  if status_after_prev.tabs[2].visible ~= false then
    error("expected second tab to be parked after ArkTabPrev, got " .. vim.inspect(status_after_prev.tabs), 0)
  end

  local active_after_close = assert(tmux.tab_close(opts))
  if active_after_close ~= second_pane then
    error("expected closing active tab to promote " .. second_pane .. ", got " .. tostring(active_after_close), 0)
  end

  local status_after_close = tmux.status(opts.tmux)
  if status_after_close.tab_count ~= 1 or status_after_close.pane_id ~= second_pane then
    error("expected one visible tab after close, got " .. vim.inspect(status_after_close), 0)
  end
  if status_after_close.parking_session_name ~= nil then
    error("expected parking session cleanup after only one tab remains, got " .. vim.inspect(status_after_close), 0)
  end

  tmux.stop_all()
  local final = tmux.status(opts.tmux)
  if final.tab_count ~= 0 or final.anchor_pane_id ~= nil then
    error("expected Ark stop_all() to clear tab state, got " .. vim.inspect(final), 0)
  end
end)

vim.fn.system = original_system

if not ok then
  error(err, 0)
end
