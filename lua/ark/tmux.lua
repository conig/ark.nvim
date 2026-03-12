local M = {}

local state = _G.__ark_nvim_state
if type(state) ~= "table" then
  state = {
    pane_id = nil,
    managed = false,
  }
end
_G.__ark_nvim_state = state

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function shellescape(value)
  return vim.fn.shellescape(tostring(value))
end

local function run_tmux(args)
  local escaped = {}
  for _, arg in ipairs(args) do
    table.insert(escaped, shellescape(arg))
  end

  local output = vim.fn.system("tmux " .. table.concat(escaped, " "))
  if vim.v.shell_error ~= 0 then
    return nil, trim(output)
  end

  return trim(output), nil
end

local function parse_percent(value, fallback)
  value = trim(value)
  if value == "" or value:sub(1, 1) == "-" then
    return nil
  end

  local pct = tonumber(value:match("(%d+)"))
  if not pct then
    return nil
  end

  if pct < 10 then
    pct = 10
  elseif pct > 90 then
    pct = 90
  end

  return tostring(pct or fallback)
end

local function pane_exists(pane_id)
  if not pane_id or pane_id == "" then
    return false
  end

  local out = run_tmux({ "list-panes", "-a", "-F", "#{pane_id}" })
  if not out then
    return false
  end

  for line in out:gmatch("[^\r\n]+") do
    if trim(line) == pane_id then
      return true
    end
  end

  return false
end

local function resolve_pane_percent(config)
  for _, key in ipairs(config.pane_width_env_keys or {}) do
    local from_format = run_tmux({ "display-message", "-p", "#{" .. key .. "}" })
    local pct = parse_percent(from_format, config.pane_percent)
    if pct then
      return pct
    end

    local env_out = run_tmux({ "show-environment", "-g", key })
    if env_out then
      local raw_value = env_out:match("^[^=]+=([^\r\n]+)$")
      pct = parse_percent(raw_value, config.pane_percent)
      if pct then
        return pct
      end
    end
  end

  return tostring(config.pane_percent)
end

local function configure_slime_target(pane_id)
  local socket_path, socket_err = run_tmux({ "display-message", "-p", "#{socket_path}" })
  if not socket_path then
    return nil, "failed to get tmux socket path: " .. tostring(socket_err or "unknown")
  end

  vim.g.slime_target = "tmux"
  vim.g.slime_default_config = {
    socket_name = socket_path,
    target_pane = pane_id,
  }
  vim.b.slime_config = vim.g.slime_default_config

  return true
end

function M.pane_command(config)
  return "clear && " .. shellescape(config.launcher)
end

function M.status()
  return {
    inside_tmux = vim.env.TMUX ~= nil and vim.env.TMUX ~= "",
    pane_id = state.pane_id,
    managed = state.managed,
    pane_exists = pane_exists(state.pane_id),
  }
end

function M.ensure(config)
  if not vim.env.TMUX or vim.env.TMUX == "" then
    return nil, "ark.nvim requires Neovim to run inside tmux"
  end

  if pane_exists(state.pane_id) then
    return state.pane_id, nil
  end

  local pane_id, split_err = run_tmux({
    "split-window",
    "-h",
    "-p",
    resolve_pane_percent(config),
    "-d",
    "-P",
    "-F",
    "#{pane_id}",
    M.pane_command(config),
  })

  if not pane_id then
    return nil, "failed to create pane: " .. tostring(split_err or "unknown")
  end

  state.pane_id = pane_id
  state.managed = true
  return pane_id, nil
end

function M.start(opts)
  local pane_id, err = M.ensure(opts.tmux)
  if not pane_id then
    return nil, err
  end

  if opts.configure_slime then
    local ok, slime_err = configure_slime_target(pane_id)
    if not ok then
      return nil, slime_err
    end
  end

  return pane_id, nil
end

function M.stop()
  if state.managed and pane_exists(state.pane_id) then
    run_tmux({ "kill-pane", "-t", state.pane_id })
  end

  state.pane_id = nil
  state.managed = false
end

function M.restart(opts)
  M.stop()
  return M.start(opts)
end

return M
