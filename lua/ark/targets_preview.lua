local M = {}
local uv = vim.uv or vim.loop
local MAX_OUTPUT_BYTES = 1024 * 1024
local MAX_RETAINED_BYTES = 8192
local MAX_RESULT_BYTES = 2 * 1024 * 1024
local active = {}
local pending_previews = {}

local function worker_path()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source))) .. "/scripts/ark-targets-preview.R"
end

local function bounded(value, default, maximum)
  return math.max(1, math.min(maximum, math.floor(tonumber(value) or default)))
end

local function validate(project, names)
  if type(project) ~= "table" then
    return "targets preview requires a project"
  end
  for _, key in ipairs({ "root", "script", "store" }) do
    if type(project[key]) ~= "string" or project[key] == "" then
      return "targets preview requires project " .. key
    end
  end
  if #names > 100 then
    return "targets preview accepts at most 100 selected target names"
  end
  for _, name in ipairs(names) do
    if type(name) ~= "string" or name == "" or #name > 1024 then
      return "invalid targets preview selection"
    end
  end
end

---Inspect on-disk targets state in an isolated R process, without a live session.
---Returns immediately. Callback runs once, including cancellation and failure.
function M.request(project, opts, callback)
  opts = opts or {}
  local names = opts.names or {}
  if type(names) == "string" then
    names = { names }
  end
  local validation = type(names) ~= "table" and "invalid targets preview selection" or validate(project, names)
  if validation then
    vim.schedule(function()
      callback(nil, validation)
    end)
    return { cancel = function() end }
  end
  local directory, directory_error = uv.fs_mkdtemp(vim.fn.tempname() .. "-preview-XXXXXX")
  if not directory then
    vim.schedule(function()
      callback(nil, "cannot create preview workspace: " .. tostring(directory_error))
    end)
    return { cancel = function() end }
  end
  local request_path, result_path = directory .. "/request.json", directory .. "/result.json"
  local handle = { output_bytes = 0, retained_output_bytes = 0 }
  local output, process, timer, abort_reason, finished = "", nil, nil, nil, false
  local function kill_worker_group()
    -- vim.system's `detach` maps to libuv's UV_PROCESS_DETACHED: on this
    -- Linux-only runtime the worker is a new process-group leader. Signal that
    -- owned group, never Neovim's group, so configuration children cannot keep
    -- stdout/stderr open and prevent the exit callback after cancellation.
    local pid = process and tonumber(process.pid)
    if not pid or pid <= 1 then
      return
    end
    local ok, result = pcall(uv.kill, -pid, 9)
    if not ok or result ~= 0 then
      -- The group may already have exited. Keep shutdown races non-throwing.
      pcall(process.kill, process, 9)
    end
  end
  local function finish(result, err)
    if finished then
      return
    end
    finished = true
    -- Also terminate owned background children that redirected their output and
    -- therefore did not delay the normal worker exit callback.
    kill_worker_group()
    active[handle] = nil
    if timer then
      timer:stop()
      timer:close()
    end
    vim.fn.delete(directory, "rf")
    callback(result, err)
  end
  local function abort(reason)
    if finished or abort_reason then
      return
    end
    abort_reason = reason
    kill_worker_group()
  end
  handle.cancel = function()
    abort("targets preview cancelled")
  end
  local function read_output(_, data)
    if not data then
      return
    end
    handle.output_bytes = handle.output_bytes + #data
    local remaining = MAX_RETAINED_BYTES - #output
    if remaining > 0 then
      output = output .. data:sub(1, remaining)
      handle.retained_output_bytes = #output
    end
    if handle.output_bytes > MAX_OUTPUT_BYTES then
      abort("targets preview exceeded output limit")
    end
  end
  local written, write_error = pcall(vim.fn.writefile, {
    vim.json.encode({
      root = project.root,
      script = project.script,
      store = project.store,
      names = names,
      max_targets = bounded(opts.max_targets, 1000, 2000),
      max_edges = bounded(opts.max_edges, 2000, 5000),
    }),
  }, request_path)
  if not written then
    vim.schedule(function()
      finish(nil, "cannot write preview request: " .. tostring(write_error))
    end)
    return handle
  end
  active[handle] = directory
  local started, start_error = pcall(function()
    process = vim.system({
      opts.r or vim.env.R_BINARY or "R",
      "--slave",
      "--no-save",
      "--no-restore",
      "--no-site-file",
      "-f",
      worker_path(),
      "--args",
      request_path,
      result_path,
    }, {
      cwd = project.root,
      detach = true,
      -- Like callr's project profile mode: allow renv activation and project
      -- library setup, but never fall back to the user's interactive profile.
      env = { R_PROFILE_USER = project.root .. "/.Rprofile" },
      stdout = read_output,
      stderr = read_output,
    }, function(exit)
      vim.schedule(function()
        if abort_reason then
          finish(nil, abort_reason)
          return
        end
        if exit.code ~= 0 then
          finish(nil, "targets preview worker exited (" .. tostring(exit.code) .. "): " .. vim.trim(output))
          return
        end
        local stat = uv.fs_stat(result_path)
        if not stat or stat.size > MAX_RESULT_BYTES then
          finish(nil, "targets preview returned no result or exceeded result size limit")
          return
        end
        local read, lines = pcall(vim.fn.readfile, result_path, "b")
        local decoded, result = false, nil
        if read then
          decoded, result = pcall(vim.json.decode, table.concat(lines, "\n"))
        end
        if not decoded or type(result) ~= "table" then
          finish(nil, "targets preview returned invalid JSON")
        elseif result.ok ~= true then
          finish(nil, tostring(result.error or "targets preview failed"))
        else
          finish(result)
        end
      end)
    end)
  end)
  if not started then
    vim.schedule(function()
      finish(nil, "cannot start targets preview worker: " .. tostring(start_error))
    end)
    return handle
  end
  timer = uv.new_timer()
  timer:start(
    bounded(opts.timeout_ms, 30000, 300000),
    0,
    vim.schedule_wrap(function()
      abort("targets preview timed out; pipeline configuration may be slow (no targets were built)")
    end)
  )
  return handle
end

local function unsaved_count(project)
  local count = 0
  local root = vim.fs.normalize(project.root):gsub("/$", "") .. "/"
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified and vim.bo[bufnr].buftype == "" then
      local path = vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr))
      if path:sub(1, #root) == root or path == project.script then
        count = count + 1
      end
    end
  end
  return count
end

local function single_line(value)
  return tostring(value):gsub("[%c]", " ")
end

function M.render(project, result, opts)
  opts = opts or {}
  local selected = opts.names or {}
  if type(selected) == "string" then
    selected = { selected }
  end
  local lines = {
    "# Ark Targets Rebuild Preview",
    "",
    "Project: " .. single_line(project.root),
    "Selection: "
      .. (
        #selected > 0 and single_line(table.concat(selected, ", ")) .. " (including upstream dependencies)"
        or "entire pipeline"
      ),
    "Source: targets::tar_outdated(); disk snapshot only, no targets built.",
    "Configuration is evaluated by two inspection APIs; its own side effects still apply.",
    "Dynamic branches are summarized by their parent targets; this is not a build-time estimate.",
  }
  local dirty = unsaved_count(project)
  if dirty > 0 then
    lines[#lines + 1] =
      string.format("WARNING: %d unsaved project buffer(s); disk preview differs from editor contents.", dirty)
  end
  if result.inconsistent then
    lines[#lines + 1] = "WARNING: configuration changed between inspections; rerun preview after stabilizing it."
  end
  vim.list_extend(lines, {
    "",
    string.format(
      "%d outdated / %d targets in scope (inspection %.0f ms)",
      result.outdated_total,
      result.target_total,
      result.elapsed_ms
    ),
    "",
    "## Targets — last recorded duration",
    "",
  })
  for _, target in ipairs(result.targets or {}) do
    local seconds = type(target.seconds) == "number" and string.format("%.3f s", target.seconds) or "not recorded"
    lines[#lines + 1] =
      string.format("%s  %s  | %s", target.outdated and "OUTDATED" or "current ", single_line(target.name), seconds)
  end
  if result.targets_truncated then
    lines[#lines + 1] = "… target display truncated; counts above cover the full selection."
  end
  vim.list_extend(lines, { "", "## Dependencies (upstream -> downstream)", "" })
  for _, edge in ipairs(result.edges or {}) do
    lines[#lines + 1] = single_line(edge.from) .. " -> " .. single_line(edge.to)
  end
  if result.edges_truncated then
    lines[#lines + 1] = "… dependency display truncated."
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "q: close / cancel pending preview"
  return lines
end

---Open a read-only asynchronous preview. Closing it cancels outstanding work.
function M.open(project, opts)
  opts = opts or {}
  local key = type(project) == "table" and project.root or ""
  if pending_previews[key] then
    pending_previews[key].cancel()
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"
  local function replace(lines)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
  end
  replace({
    "# Ark Targets Rebuild Preview",
    "",
    "Checking the on-disk pipeline in a separate R process…",
    "No targets will be built. Configuration code will run; its side effects still apply.",
    "",
    "q: cancel / close",
  })
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, bufnr)
  local handle
  handle = M.request(project, opts, function(result, err)
    if pending_previews[key] == handle then
      pending_previews[key] = nil
    end
    replace(
      result and M.render(project, result, opts)
        or { "# Ark Targets Rebuild Preview", "", "Preview unavailable: " .. single_line(err), "", "q: close" }
    )
    if opts.on_complete then
      opts.on_complete(result, err)
    end
  end)
  pending_previews[key] = handle
  handle.bufnr = bufnr
  vim.keymap.set("n", "q", function()
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end, { buffer = bufnr, silent = true })
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = bufnr, once = true, callback = handle.cancel })
  return handle
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    for handle, directory in pairs(active) do
      handle.cancel()
      -- Neovim may exit before the process callback can run cleanup.
      vim.fn.delete(directory, "rf")
    end
  end,
})

return M
