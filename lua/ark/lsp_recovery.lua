local M = {}
local notifications = require("ark.notifications")
local uv = vim.uv or vim.loop

local DEFAULTS = {
  enabled = true,
  max_restarts = 3,
  window_ms = 30000,
  base_delay_ms = 250,
  max_delay_ms = 2000,
}

local intentional_stops = {}
local recovery_states = {}

local function notification_key(kind, key)
  return "lsp-crash-" .. kind .. "-" .. key
end

local function clear_notifications(key)
  notifications.clear(notification_key("recovery", key))
  notifications.clear(notification_key("loop", key))
  notifications.clear(notification_key("recovery-failed", key))
end

local function monotonic_ms()
  local clock = (uv and uv.hrtime) and uv.hrtime or vim.loop.hrtime
  return math.floor(clock() / 1e6)
end

local function recovery_opts(configured)
  configured = type(configured) == "table" and configured or {}
  return vim.tbl_extend("force", DEFAULTS, configured)
end

local function recovery_key(name, root_dir)
  return table.concat({ name, root_dir or "" }, "\0")
end

function M.mark_intentional(client)
  if type(client) ~= "table" or type(client.id) ~= "number" then
    return
  end
  if not client.config or not client.config._ark_lsp_exit_handler then
    return
  end

  intentional_stops[client.id] = true
end

function M.reset(name, root_dir)
  local key = recovery_key(name, root_dir)
  local state = recovery_states[key]
  if state then
    state.generation = state.generation + 1
    recovery_states[key] = nil
  end
  clear_notifications(key)
end

function M.configure(config, context)
  local opts = recovery_opts(context.opts)
  local key = recovery_key(context.name, config.root_dir)
  local start_opts = vim.deepcopy(context.start_opts or {})

  config._ark_lsp_exit_handler = true
  config.on_exit = function(code, signal, client_id)
    context.forget_client(client_id)
    if type(client_id) == "number" and intentional_stops[client_id] then
      intentional_stops[client_id] = nil
      return
    end
    if opts.enabled == false then
      return
    end

    vim.schedule(function()
      local buffers = context.matching_buffers()
      if #buffers == 0 then
        return
      end

      local now = monotonic_ms()
      local state = recovery_states[key]
      if not state or now - state.window_started_ms >= opts.window_ms then
        clear_notifications(key)
        state = {
          attempts = 0,
          generation = 0,
          window_started_ms = now,
        }
        recovery_states[key] = state
      end

      state.attempts = state.attempts + 1
      state.generation = state.generation + 1
      if state.attempts > opts.max_restarts then
        notifications.emit(
          string.format(
            "ark-lsp exited repeatedly (code %s, signal %s); automatic recovery stopped after %d attempts. Run :ArkRefresh after checking :checkhealth ark.",
            tostring(code),
            tostring(signal),
            opts.max_restarts
          ),
          vim.log.levels.ERROR,
          { ark_key = notification_key("loop", key) }
        )
        return
      end

      local delay_ms = math.min(opts.base_delay_ms * (2 ^ (state.attempts - 1)), opts.max_delay_ms)
      local generation = state.generation
      notifications.emit(
        string.format(
          "ark-lsp exited unexpectedly (code %s, signal %s); restarting in %d ms (attempt %d/%d).",
          tostring(code),
          tostring(signal),
          delay_ms,
          state.attempts,
          opts.max_restarts
        ),
        vim.log.levels.WARN,
        { ark_key = notification_key("recovery", key) }
      )

      vim.defer_fn(function()
        if recovery_states[key] ~= state or state.generation ~= generation then
          return
        end

        for _, bufnr in ipairs(context.matching_buffers()) do
          if not context.has_live_client(bufnr) then
            local ok, err = xpcall(function()
              context.start(bufnr, start_opts)
            end, debug.traceback)
            if not ok then
              notifications.emit(
                "ark-lsp automatic recovery failed: " .. tostring(err),
                vim.log.levels.ERROR,
                { ark_key = notification_key("recovery-failed", key) }
              )
              return
            end
          end
        end
      end, delay_ms)
    end)
  end
end

return M
