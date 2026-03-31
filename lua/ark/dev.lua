local uv = vim.uv or vim.loop

local M = {}

local function repo_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local ROOT = repo_root()
local BUILD_CMD = { "cargo", "build", "-p", "ark", "--bin", "ark-lsp" }
local SPINNER_FRAMES = { "[=   ]", "[==  ]", "[=== ]", "[ ===]", "[  ==]", "[   =]" }
local checked = {}
local build_state = {
  listeners = {},
  notify_id = nil,
  output = {},
  output_buf = nil,
  output_win = nil,
  running = false,
  show_output = false,
  spinner_index = 1,
  spinner_timer = nil,
  started_at = nil,
}

local function normalize_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end

  return vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(path), ":p"))
end

local function stat_mtime(path)
  local stat = uv and uv.fs_stat and uv.fs_stat(path) or nil
  return stat and stat.mtime and stat.mtime.sec or nil
end

local function repo_target_binary(path)
  local normalized = normalize_path(path)
  if not normalized then
    return nil
  end

  if not vim.startswith(normalized, ROOT .. "/target/") then
    return nil
  end

  return normalized
end

local function rust_source_paths()
  local paths = {}

  if vim.fn.executable("rg") == 1 then
    paths = vim.fn.systemlist({
      "rg",
      "--files",
      ROOT .. "/crates/ark/src",
      ROOT .. "/crates/ark_test/src",
    })
    if vim.v.shell_error ~= 0 then
      paths = {}
    end
  end

  paths[#paths + 1] = ROOT .. "/crates/ark/Cargo.toml"
  paths[#paths + 1] = ROOT .. "/crates/ark_test/Cargo.toml"
  paths[#paths + 1] = ROOT .. "/Cargo.lock"

  return paths
end

local function newest_source_mtime()
  local newest_mtime = 0
  local newest_path = nil

  for _, path in ipairs(rust_source_paths()) do
    local mtime = stat_mtime(path)
    if type(mtime) == "number" and mtime > newest_mtime then
      newest_mtime = mtime
      newest_path = path
    end
  end

  return newest_mtime, newest_path
end

local function binary_path()
  return ROOT .. "/target/debug/ark-lsp"
end

local function elapsed_ms()
  if not build_state.started_at then
    return nil
  end

  local now = ((uv and uv.hrtime) and uv.hrtime()) or vim.loop.hrtime()
  return math.floor((now - build_state.started_at) / 1e6)
end

local function notify(message, level, opts)
  local notify_opts = vim.tbl_extend("force", {
    title = "ark.nvim",
  }, opts or {})
  local id = vim.notify(message, level or vim.log.levels.INFO, notify_opts)
  if id ~= nil then
    build_state.notify_id = id
  end
end

local function stop_spinner()
  if build_state.spinner_timer then
    build_state.spinner_timer:stop()
    build_state.spinner_timer:close()
    build_state.spinner_timer = nil
  end
end

local function spinner_message()
  local frame = SPINNER_FRAMES[build_state.spinner_index] or SPINNER_FRAMES[1]
  return "Rebuilding detached ark-lsp " .. frame
end

local function start_spinner()
  notify(spinner_message(), vim.log.levels.INFO, {
    hide_from_history = true,
  })

  if not (uv and uv.new_timer) then
    return
  end

  build_state.spinner_timer = uv.new_timer()
  build_state.spinner_timer:start(120, 120, function()
    vim.schedule(function()
      if not build_state.running then
        stop_spinner()
        return
      end

      build_state.spinner_index = (build_state.spinner_index % #SPINNER_FRAMES) + 1
      notify(spinner_message(), vim.log.levels.INFO, {
        hide_from_history = true,
        replace = build_state.notify_id,
      })
    end)
  end)
end

local function ensure_output_buffer()
  if build_state.output_buf and vim.api.nvim_buf_is_valid(build_state.output_buf) then
    return build_state.output_buf
  end

  build_state.output_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[build_state.output_buf].bufhidden = "wipe"
  vim.bo[build_state.output_buf].buftype = "nofile"
  vim.bo[build_state.output_buf].filetype = "log"
  vim.bo[build_state.output_buf].modifiable = true
  return build_state.output_buf
end

local function ensure_output_window()
  local buf = ensure_output_buffer()
  if build_state.output_win and vim.api.nvim_win_is_valid(build_state.output_win) then
    vim.api.nvim_win_set_buf(build_state.output_win, buf)
    return build_state.output_win
  end

  local width = math.max(80, math.floor(vim.o.columns * 0.7))
  local height = math.max(12, math.floor(vim.o.lines * 0.35))
  build_state.output_win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(1, math.floor((vim.o.columns - width) / 2)),
    width = math.min(width, vim.o.columns - 4),
    height = math.min(height, vim.o.lines - 4),
    border = "rounded",
    style = "minimal",
    title = " ark-lsp build ",
    title_pos = "center",
  })

  return build_state.output_win
end

local function reset_output()
  build_state.output = {
    "$ " .. table.concat(BUILD_CMD, " "),
    "",
  }

  if build_state.output_buf and vim.api.nvim_buf_is_valid(build_state.output_buf) then
    vim.bo[build_state.output_buf].modifiable = true
    vim.api.nvim_buf_set_lines(build_state.output_buf, 0, -1, false, build_state.output)
  end
end

local function append_output(data)
  if type(data) ~= "table" or #data == 0 then
    return
  end

  local lines = {}
  for _, line in ipairs(data) do
    if type(line) == "string" then
      lines[#lines + 1] = line
    end
  end
  if #lines == 0 then
    return
  end

  vim.list_extend(build_state.output, lines)

  if build_state.show_output ~= true then
    return
  end

  local buf = ensure_output_buffer()
  ensure_output_window()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  if build_state.output_win and vim.api.nvim_win_is_valid(build_state.output_win) then
    local last = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(build_state.output_win, { last, 0 })
  end
end

local function finish_build(result)
  stop_spinner()
  build_state.running = false

  local listeners = build_state.listeners
  build_state.listeners = {}

  if result.ok then
    checked = {}
    local ms = elapsed_ms()
    local suffix = ms and string.format(" in %d ms", ms) or ""
    notify("detached ark-lsp rebuilt" .. suffix, vim.log.levels.INFO, {
      replace = build_state.notify_id,
    })
  else
    build_state.show_output = true
    ensure_output_window()
    notify("detached ark-lsp rebuild failed; cargo output opened in a floating window", vim.log.levels.ERROR, {
      replace = build_state.notify_id,
    })
  end

  build_state.notify_id = nil
  build_state.started_at = nil
  build_state.spinner_index = 1

  for _, listener in ipairs(listeners) do
    pcall(listener, result)
  end
end

local function start_build(opts)
  if vim.fn.executable("cargo") ~= 1 then
    return false, "`cargo` is not available to rebuild `ark-lsp`"
  end

  if vim.fn.exists("*jobstart") ~= 1 then
    return false, "this Neovim does not support `jobstart()`, so automatic `ark-lsp` rebuild is unavailable"
  end

  if build_state.running then
    if opts and opts.on_complete then
      build_state.listeners[#build_state.listeners + 1] = opts.on_complete
    end
    if opts and opts.show_output == true then
      build_state.show_output = true
      ensure_output_window()
    end
    return true, nil
  end

  build_state.running = true
  build_state.show_output = opts and opts.show_output == true or false
  build_state.listeners = {}
  if opts and opts.on_complete then
    build_state.listeners[#build_state.listeners + 1] = opts.on_complete
  end
  build_state.started_at = ((uv and uv.hrtime) and uv.hrtime()) or vim.loop.hrtime()
  build_state.spinner_index = 1
  reset_output()
  if build_state.show_output then
    ensure_output_window()
  end
  start_spinner()

  local job_id = vim.fn.jobstart(BUILD_CMD, {
    cwd = ROOT,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      vim.schedule(function()
        append_output(data)
      end)
    end,
    on_stderr = function(_, data)
      vim.schedule(function()
        append_output(data)
      end)
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local path = binary_path()
        if code == 0 and stat_mtime(path) then
          finish_build({
            ok = true,
            binary_path = path,
          })
          return
        end

        local output = vim.trim(table.concat(build_state.output, "\n"))
        if output == "" then
          output = "cargo build failed"
        end
        finish_build({
          ok = false,
          error = output,
        })
      end)
    end,
  })

  if job_id <= 0 then
    build_state.running = false
    stop_spinner()
    build_state.notify_id = nil
    build_state.started_at = nil
    return false, "failed to start cargo build for detached ark-lsp"
  end

  return true, nil
end

function M.ensure_current_detached_lsp_cmd(cmd, opts)
  opts = opts or {}

  if type(cmd) ~= "table" or type(cmd[1]) ~= "string" or cmd[1] == "" then
    return cmd, nil
  end

  local binary = repo_target_binary(cmd[1])
  if not binary then
    return cmd, nil
  end

  local newest_mtime, newest_path = newest_source_mtime()
  local binary_mtime = stat_mtime(binary) or 0
  local cache_key = table.concat({
    binary,
    tostring(binary_mtime),
    tostring(newest_mtime),
  }, "::")

  if checked[cache_key] then
    local updated = vim.deepcopy(cmd)
    updated[1] = binary
    return updated, nil
  end

  if binary_mtime == 0 or (type(newest_mtime) == "number" and newest_mtime > binary_mtime) then
    local ok, build_err = start_build({
      on_complete = opts.on_build_complete,
      show_output = opts.show_build_output == true,
      user_initiated = opts.user_initiated == true,
    })
    if not ok then
      return nil, string.format(
        "detached ark-lsp binary is stale relative to %s and rebuild failed to start: %s",
        newest_path or "Rust sources",
        build_err
      )
    end

    return nil, {
      kind = "build_pending",
      message = "Rebuilding detached ark-lsp...",
    }
  end

  checked[cache_key] = true

  local updated = vim.deepcopy(cmd)
  updated[1] = binary
  return updated, nil
end

function M.detached_lsp_build_fingerprint(path)
  local binary = repo_target_binary(path)
  if not binary then
    return nil
  end

  return table.concat({
    binary,
    tostring(stat_mtime(binary) or 0),
  }, "::")
end

function M.build_detached_lsp(opts)
  opts = opts or {}
  return start_build({
    on_complete = opts.on_complete,
    show_output = opts.show_output ~= false,
    user_initiated = true,
  })
end

return M
