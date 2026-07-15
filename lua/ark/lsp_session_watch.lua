local uv = vim.uv or vim.loop

local M = {}

local function same_session_identity(lhs, rhs)
  if type(lhs) ~= "table" or type(rhs) ~= "table" then
    return false
  end
  return (lhs.kind or "") == (rhs.kind or "")
    and (lhs.backend or "") == (rhs.backend or "")
    and (lhs.sessionId or "") == (rhs.sessionId or "")
    and (lhs.statusFile or "") == (rhs.statusFile or "")
    and (lhs.tmuxSocket or "") == (rhs.tmuxSocket or "")
    and (lhs.tmuxSession or "") == (rhs.tmuxSession or "")
    and (lhs.tmuxPane or "") == (rhs.tmuxPane or "")
end

local function status_unavailable(payload)
  return type(payload) ~= "table"
    or ((payload.status == nil or payload.status == "") and payload.replReady ~= true)
end

function M.new(deps)
  vim.validate({
    filetype_enabled = { deps.filetype_enabled, "function" },
    on_detach = { deps.on_detach, "function", true },
    resolve_bufnr = { deps.resolve_bufnr, "function" },
  })

  local watches = {}
  local buffer_cleanup = {}
  local buffer_keys = {}
  local next_generation = 0
  local poll_ms = tonumber(deps.poll_ms) or 50
  local controller = {}

  function controller.suppress_stale_payload(previous, current)
    return type(previous) == "table"
      and previous.status == "ready"
      and previous.replReady == true
      and status_unavailable(current)
      and same_session_identity(previous, current)
  end

  local function close_handle(handle)
    if not handle then
      return
    end
    pcall(handle.stop, handle)
    pcall(handle.close, handle)
  end

  function controller.buffers(watch)
    local buffers = {}
    if type(watch) ~= "table" then
      return buffers
    end

    for bufnr, _ in pairs(watch.bufnrs or {}) do
      if vim.api.nvim_buf_is_valid(bufnr) and buffer_keys[bufnr] == watch.key then
        buffers[#buffers + 1] = bufnr
      end
    end
    return buffers
  end

  function controller.first_buffer(watch)
    return controller.buffers(watch)[1]
  end

  local function has_buffers(watch)
    return controller.first_buffer(watch) ~= nil
  end

  function controller.stop(key)
    local watch = watches[key]
    if type(watch) ~= "table" then
      return
    end

    close_handle(watch.watcher)
    watch.watcher = nil
    watch.poll_token = nil

    for bufnr, _ in pairs(watch.bufnrs or {}) do
      if buffer_keys[bufnr] == key then
        buffer_keys[bufnr] = nil
      end
    end
    watches[key] = nil
  end

  function controller.detach(bufnr)
    local key = buffer_keys[bufnr]
    buffer_keys[bufnr] = nil
    buffer_cleanup[bufnr] = nil
    if type(deps.on_detach) == "function" then
      deps.on_detach(bufnr)
    end

    if type(key) ~= "string" or key == "" then
      return
    end
    local watch = watches[key]
    if type(watch) ~= "table" then
      return
    end

    watch.bufnrs[bufnr] = nil
    if not has_buffers(watch) then
      controller.stop(key)
    end
  end

  local function attach(status_path, bufnr)
    local current_key = buffer_keys[bufnr]
    if current_key and current_key ~= status_path then
      controller.detach(bufnr)
    end

    local watch = watches[status_path]
    if type(watch) ~= "table" then
      next_generation = next_generation + 1
      watch = {
        key = status_path,
        generation = next_generation,
        bufnrs = {},
        watcher = nil,
        poll_token = nil,
      }
      watches[status_path] = watch
    end

    watch.bufnrs[bufnr] = true
    buffer_keys[bufnr] = status_path
    return watch
  end

  local function ensure_cleanup(bufnr)
    if buffer_cleanup[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    buffer_cleanup[bufnr] = true
    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
      buffer = bufnr,
      once = true,
      callback = function()
        controller.detach(bufnr)
      end,
    })
  end

  local function watch_status_file(status_path, on_change)
    if not uv or type(status_path) ~= "string" or status_path == "" then
      return nil
    end
    local watch_path = vim.fs.dirname(status_path)
    if type(watch_path) ~= "string" or watch_path == "" then
      return nil
    end

    vim.fn.mkdir(watch_path, "p")
    local scheduled = false
    local function trigger()
      if scheduled then
        return
      end
      scheduled = true
      vim.schedule(function()
        scheduled = false
        on_change()
      end)
    end

    if uv.new_fs_event then
      local watcher = uv.new_fs_event()
      if watcher then
        local ok = watcher:start(watch_path, {}, trigger)
        if ok then
          return watcher
        end
        close_handle(watcher)
      end
    end
    return nil
  end

  local function current_watch(key, generation)
    local watch = watches[key]
    if type(watch) ~= "table" or watch.generation ~= generation then
      return nil
    end
    return watch
  end

  local function process_update(opts, watch, callbacks, source)
    local current = callbacks.payload(opts, controller.first_buffer(watch))
    if current.statusFile ~= watch.key then
      controller.stop(watch.key)
      return true
    end

    callbacks.notify(opts, watch, current)
    callbacks.bootstrap(opts, watch, current, source)
    if callbacks.finished(opts, nil, current) then
      controller.stop(watch.key)
      return true
    end
    if callbacks.poll_finished(opts, watch, current) then
      watch.poll_token = nil
      return true
    end
    return false
  end

  local function start_poll(opts, status_path, callbacks)
    local watch = watches[status_path]
    if type(watch) ~= "table" then
      return nil
    end
    if watch.poll_token ~= nil then
      return watch
    end

    local token = {}
    local generation = watch.generation
    watch.poll_token = token
    local function poll()
      local active = current_watch(status_path, generation)
      if not active or active.poll_token ~= token then
        return
      end
      if process_update(opts, active, callbacks, callbacks.poll_source) then
        return
      end
      vim.defer_fn(poll, poll_ms)
    end

    vim.defer_fn(poll, poll_ms)
    return watch
  end

  function controller.ensure(opts, bufnr, payload, callbacks)
    bufnr = deps.resolve_bufnr(bufnr) or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      controller.detach(bufnr)
      return nil
    end
    if not deps.filetype_enabled(opts.filetypes, vim.bo[bufnr].filetype) then
      controller.detach(bufnr)
      return nil
    end

    local current_payload = payload or callbacks.payload(opts, bufnr)
    local status_path = current_payload.statusFile
    if type(status_path) ~= "string" or status_path == "" then
      controller.detach(bufnr)
      return nil
    end

    local watch = attach(status_path, bufnr)
    ensure_cleanup(bufnr)
    if callbacks.notify_immediately ~= false then
      callbacks.notify(opts, watch, current_payload)
    end
    if callbacks.finished(opts, bufnr, current_payload) then
      controller.stop(watch.key)
      return watch
    end

    if not watch.watcher then
      local watch_key = watch.key
      local generation = watch.generation
      local watcher = watch_status_file(status_path, function()
        local active = current_watch(watch_key, generation)
        if not active then
          return
        end
        if not process_update(opts, active, callbacks, callbacks.watch_source) then
          start_poll(opts, watch_key, callbacks)
        end
      end)
      if watcher then
        watch.watcher = watcher
      end
    end

    if watch.watcher then
      return watch
    end
    return start_poll(opts, status_path, callbacks)
  end

  return controller
end

return M
