-- Explicit error inspection only. Frames are never copied to support reports or
-- logs, and source navigation requires a genuine location from R's srcref.
local M = {}
local pending
local generation = 0
local workers = {}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "ark.nvim" })
end

local function show(payload, origin)
  local frames = payload.frames or {}
  if not payload.available or #frames == 0 then
    notify(
      payload.message or "No uncaught error traceback is available. Caught errors do not replace R's last traceback."
    )
    return
  end
  local target = payload.source == "target_workspace"
  local prompt = target and "Saved target traceback (call text only)" or "Last uncaught R error (newest call first)"
  if payload.truncated then
    prompt = prompt .. " — first 128 frames"
  end
  vim.ui.select(frames, {
    prompt = prompt,
    format_item = function(frame)
      local location = frame.path and frame.line and (" — " .. frame.path .. ":" .. frame.line)
        or " [no source location]"
      return tostring(frame.index or "?") .. ": " .. tostring(frame.call or ""):gsub("[\r\n]", " ") .. location
    end,
  }, function(frame)
    if not frame then
      return
    end
    if type(frame.path) ~= "string" or type(frame.line) ~= "number" or frame.line < 1 then
      notify("This frame has no source reference; its call text is available in the traceback picker.")
      return
    end
    if vim.fn.filereadable(frame.path) ~= 1 then
      notify("Traceback source file is no longer readable", vim.log.levels.WARN)
      return
    end
    -- Selecting a call must not run code, interpret filenames as Ex, or jump to
    -- an arbitrary current window after the picker closes.
    vim.schedule(function()
      if not vim.api.nvim_win_is_valid(origin) then
        return
      end
      local buf = vim.fn.bufadd(frame.path)
      vim.fn.bufload(buf)
      if frame.line > vim.api.nvim_buf_line_count(buf) then
        notify("Traceback source line no longer exists; the file may have changed", vim.log.levels.WARN)
        return
      end
      local ok, err = pcall(function()
        vim.api.nvim_set_current_win(origin)
        vim.api.nvim_win_set_buf(origin, buf)
        vim.api.nvim_win_set_cursor(origin, { frame.line, 0 })
      end)
      if not ok then
        notify("Cannot open traceback source: " .. tostring(err), vim.log.levels.WARN)
      end
    end)
  end)
end

-- request(callback) follows lsp_request_adapter's (started, error, cancel)
-- convention. A second explicit request cancels/discards the superseded one.
function M.open(request)
  M.cancel()
  local current = generation
  local origin = vim.api.nvim_get_current_win()
  local completed = false
  local function on_reply(payload, request_err)
    completed = true
    vim.schedule(function()
      if current ~= generation then
        return
      end
      pending = nil
      if request_err or not payload or payload.error or payload.status == "error" then
        notify(
          "Traceback unavailable: "
            .. tostring(
              request_err
                or (payload and (payload.message or (payload.error and payload.error.message)))
                or "bridge request failed"
            ),
          vim.log.levels.WARN
        )
        return
      end
      show(payload, origin)
    end)
  end
  local started, err, cancel = request(on_reply)
  if not started and not completed then
    on_reply(nil, err or "request failed")
  end
  if not completed then
    pending = cancel
  end
  return started, err
end

function M.cancel()
  generation = generation + 1
  if pending then
    pending()
    pending = nil
  end
end

function M.target_request(project, name, callback)
  if type(project) ~= "table" or type(project.root) ~= "string" or type(project.store) ~= "string" then
    callback(nil, "targets project unavailable")
    return nil, "targets project unavailable"
  end
  if type(name) ~= "string" or name == "" then
    callback(nil, "a target name is required")
    return nil, "a target name is required"
  end
  local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p", 448) -- Traceback call text may contain private arguments.
  local output = directory .. "/traceback.json"
  local request = vim.json.encode({ name = name, store = project.store })
  local cancelled = false
  local stderr = ""
  local ok, process = pcall(vim.system, {
    vim.env.ARK_NVIM_R_BIN or "R",
    "--slave",
    "--vanilla",
    "-f",
    root .. "/scripts/ark-target-traceback.R",
    "--args",
    request,
    output,
  }, {
    cwd = project.root,
    timeout = 15000,
    stdout = false,
    stderr = function(_, data)
      if data and #stderr < 4096 then
        stderr = stderr .. data:sub(1, 4096 - #stderr)
      end
    end,
  }, function(result)
    vim.schedule(function()
      local payload
      local info = vim.uv.fs_stat(output)
      local oversized = info and info.size > 1024 * 1024
      if result.code == 0 and info and not oversized and vim.fn.filereadable(output) == 1 then
        local decoded, value = pcall(vim.json.decode, table.concat(vim.fn.readfile(output), "\n"))
        if decoded and type(value) == "table" then
          payload = value
        end
      end
      workers[directory] = nil
      vim.fn.delete(directory, "rf")
      if not cancelled then
        local err
        if not payload then
          err = oversized and "saved traceback response exceeded size limit"
            or (result.code == 124 and "saved traceback inspection timed out")
            or (stderr ~= "" and stderr or "saved traceback inspection failed")
        end
        callback(payload, err)
      end
    end)
  end)
  if not ok then
    vim.fn.delete(directory, "rf")
    callback(nil, tostring(process))
    return nil, tostring(process)
  end
  local function cancel()
    cancelled = true
    process:kill(15)
  end
  workers[directory] = cancel
  return true, nil, cancel
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    M.cancel()
    for directory, cancel in pairs(workers) do
      cancel()
      vim.fn.delete(directory, "rf")
    end
  end,
})

return M
