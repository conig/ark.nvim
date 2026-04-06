vim.opt.rtp:prepend(vim.fn.getcwd())

_G.__ark_nvim_state = {}
package.loaded["ark.tmux"] = nil

local original_system = vim.fn.system

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
    return pane_id .. "\n" .. socket_path .. "\n" .. main_session .. "\n"
  end

  if command[2] == "new-window" then
    local pane_id = new_pane(main_session)
    local window_id = new_window_id()
    return pane_id .. "\n" .. window_id .. "\n" .. socket_path .. "\n" .. main_session .. "\n"
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
  local startup_session_queries = 0
  for _, command in ipairs(commands) do
    if type(command) == "table"
      and command[2] == "display-message"
      and command[3] == "-p"
      and command[4] == "-t"
      and command[6] == "#{socket_path}\n#{session_name}"
    then
      startup_session_queries = startup_session_queries + 1
    end
  end
  if startup_session_queries ~= 1 then
    error("expected initial start to resolve pane session metadata once, got commands: " .. vim.inspect(commands), 0)
  end
  local tab_state_after_start = tmux.tab_state()
  if tab_state_after_start.active_index ~= 1 or tab_state_after_start.tab_count ~= 1 or tab_state_after_start.text ~= "[1]" then
    error("expected tab state after start to report one active tab, got " .. vim.inspect(tab_state_after_start), 0)
  end

  local second_pane = assert(tmux.tab_new(opts))
  if second_pane == first_pane then
    error("expected ArkTabNew to create a distinct visible pane, got " .. tostring(second_pane), 0)
  end
  local split_count = 0
  local new_window_count = 0
  local swap_count = 0
  for _, command in ipairs(commands) do
    if type(command) == "table" and command[2] == "split-window" then
      split_count = split_count + 1
    elseif type(command) == "table" and command[2] == "new-window" then
      new_window_count = new_window_count + 1
    elseif type(command) == "table" and command[2] == "swap-pane" then
      swap_count = swap_count + 1
    end
  end
  if split_count ~= 1 then
    error("expected only the initial Ark slot creation to use split-window, got commands: " .. vim.inspect(commands), 0)
  end
  if new_window_count < 1 or swap_count < 1 then
    error("expected ArkTabNew to create a hidden window and swap it into place, got commands: " .. vim.inspect(commands), 0)
  end

  local status_after_new = tmux.status(opts.tmux)
  if status_after_new.tab_count ~= 2 then
    error("expected two tabs after ArkTabNew, got " .. vim.inspect(status_after_new), 0)
  end
  if status_after_new.active_index ~= 2 then
    error("expected second tab to be active after ArkTabNew, got " .. vim.inspect(status_after_new), 0)
  end
  if status_after_new.tabs[1].visible ~= false then
    error("expected first tab to be parked, got " .. vim.inspect(status_after_new.tabs), 0)
  end
  if status_after_new.tabs[1].session.tmux_session ~= main_session then
    error("expected parked tab to retain startup session metadata, got " .. vim.inspect(status_after_new.tabs[1]), 0)
  end
  local tab_state_after_new = tmux.tab_state()
  if tab_state_after_new.active_index ~= 2 or tab_state_after_new.tab_count ~= 2 or tab_state_after_new.text ~= "[2/2]" then
    error("expected tab state after ArkTabNew to report the new active tab, got " .. vim.inspect(tab_state_after_new), 0)
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
  local tab_state_after_prev = tmux.tab_state()
  if tab_state_after_prev.active_index ~= 1 or tab_state_after_prev.tab_count ~= 2 or tab_state_after_prev.text ~= "[1/2]" then
    error("expected tab state after ArkTabPrev to report the restored tab, got " .. vim.inspect(tab_state_after_prev), 0)
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
    error("expected no detached parking session after close, got " .. vim.inspect(status_after_close), 0)
  end

  local restarted_pane = assert(tmux.restart(opts))
  if restarted_pane == second_pane then
    error("expected restart to replace the active pane, got " .. tostring(restarted_pane), 0)
  end
  split_count = 0
  new_window_count = 0
  swap_count = 0
  for _, command in ipairs(commands) do
    if type(command) == "table" and command[2] == "split-window" then
      split_count = split_count + 1
    elseif type(command) == "table" and command[2] == "new-window" then
      new_window_count = new_window_count + 1
    elseif type(command) == "table" and command[2] == "swap-pane" then
      swap_count = swap_count + 1
    end
  end
  if split_count ~= 1 then
    error("expected restart to preserve the visible slot without extra split-window churn, got commands: " .. vim.inspect(commands), 0)
  end
  if new_window_count < 2 or swap_count < 3 then
    error("expected restart to create a hidden replacement and swap it into place, got commands: " .. vim.inspect(commands), 0)
  end
  local tab_state_after_restart = tmux.tab_state()
  if tab_state_after_restart.active_index ~= 1 or tab_state_after_restart.tab_count ~= 1 or tab_state_after_restart.text ~= "[1]" then
    error("expected tab state after restart to report the replacement tab, got " .. vim.inspect(tab_state_after_restart), 0)
  end

  tmux.stop_all()
  local final = tmux.status(opts.tmux)
  if final.tab_count ~= 0 or final.anchor_pane_id ~= nil then
    error("expected Ark stop_all() to clear tab state, got " .. vim.inspect(final), 0)
  end
  local final_tab_state = tmux.tab_state()
  if final_tab_state.active_index ~= nil or final_tab_state.tab_count ~= 0 or final_tab_state.text ~= nil then
    error("expected Ark stop_all() to clear lightweight tab state, got " .. vim.inspect(final_tab_state), 0)
  end
end)

vim.fn.system = original_system

if not ok then
  error(err, 0)
end
