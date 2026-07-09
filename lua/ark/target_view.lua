local M = {}

local uv = vim.uv or vim.loop

local next_request_id = 0

local function plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

local function r_string_literal(value)
  return '"' .. tostring(value or ""):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function shell_path(path)
  return vim.fs.normalize(path)
end

local function arkbridge_sources()
  local root = plugin_root()
  local bridge = shell_path(root .. "/packages/arkbridge/R")
  return {
    bridge .. "/utils.R",
    bridge .. "/schema.R",
    bridge .. "/io.R",
    bridge .. "/ipc_service.R",
    bridge .. "/view.R",
    bridge .. "/targets.R",
  }
end

local function worker_script_lines(session_id)
  local sources = {}
  for _, source in ipairs(arkbridge_sources()) do
    sources[#sources + 1] = r_string_literal(source)
  end

  return {
    "options(warn = 1)",
    "for (.ark_source in c(" .. table.concat(sources, ", ") .. ")) {",
    "  source(.ark_source, local = .GlobalEnv, keep.source = FALSE)",
    "}",
    ".ark_target_view_session <- list(session_id = " .. r_string_literal(session_id) .. ", backend = 'target-store')",
    ".ark_worker_emit <- function(request_id, payload) {",
    "  payload$request_id <- request_id %||% ''",
    "  cat(jsonlite::toJSON(payload, auto_unbox = TRUE, null = 'null', pretty = FALSE, force = TRUE), '\\n', sep = '')",
    "  flush.console()",
    "}",
    ".ark_worker_error <- function(request_id, message, code = 'E_TARGET_VIEW') {",
    "  .ark_worker_emit(request_id, .new_error_payload(code, message, 'target_view_worker', .ark_target_view_session))",
    "}",
    ".ark_worker_payload <- function(req) {",
    "  command <- req$command %||% ''",
    "  if (identical(command, 'targets_view_open')) {",
    "    return(.ark_targets_view_open_payload(.ark_target_view_session, req$root %||% '', req$script %||% '', req$store %||% '', req$name %||% ''))",
    "  }",
    "  if (identical(command, 'view_state')) return(.ark_view_state_payload(.ark_target_view_session, req$session_id %||% ''))",
    "  if (identical(command, 'view_page')) return(.ark_view_page_payload(.ark_target_view_session, req$session_id %||% '', req$offset %||% 0L, req$limit %||% 0L, req$columns %||% integer()))",
    "  if (identical(command, 'view_sort')) return(.ark_view_sort_payload(.ark_target_view_session, req$session_id %||% '', req$column_index %||% 0L, req$direction %||% ''))",
    "  if (identical(command, 'view_filter')) return(.ark_view_filter_payload(.ark_target_view_session, req$session_id %||% '', req$column_index %||% 0L, req$query %||% '', req$mode %||% 'contains', req$value_key %||% '', req$label %||% ''))",
    "  if (identical(command, 'view_values')) return(.ark_view_values_payload(.ark_target_view_session, req$session_id %||% '', req$column_index %||% 0L))",
    "  if (identical(command, 'view_schema_search')) return(.ark_view_schema_search_payload(.ark_target_view_session, req$session_id %||% '', req$query %||% ''))",
    "  if (identical(command, 'view_profile')) return(.ark_view_profile_payload(.ark_target_view_session, req$session_id %||% '', req$column_index %||% 0L))",
    "  if (identical(command, 'view_code')) return(.ark_view_code_payload(.ark_target_view_session, req$session_id %||% ''))",
    "  if (identical(command, 'view_export')) return(.ark_view_export_payload(.ark_target_view_session, req$session_id %||% '', req$format %||% 'tsv'))",
    "  if (identical(command, 'view_cell')) return(.ark_view_cell_payload(.ark_target_view_session, req$session_id %||% '', req$row_index %||% 0L, req$column_index %||% 0L))",
    "  if (identical(command, 'view_close')) return(.ark_view_close_payload(.ark_target_view_session, req$session_id %||% ''))",
    "  if (identical(command, 'object_children')) return(.ark_object_children_payload(.ark_target_view_session, req$session_id %||% '', req$node_id %||% '', req$offset %||% 0L, req$limit %||% 0L))",
    "  if (identical(command, 'object_detail')) return(.ark_object_detail_payload(.ark_target_view_session, req$session_id %||% '', req$node_id %||% ''))",
    "  if (identical(command, 'object_table')) return(.ark_object_table_payload(.ark_target_view_session, req$session_id %||% '', req$node_id %||% ''))",
    "  if (identical(command, 'object_search')) return(.ark_object_search_payload(.ark_target_view_session, req$session_id %||% '', req$query %||% '', req$max_nodes %||% 1000L, req$max_results %||% 100L))",
    "  .emit_json(.new_error_payload('E_IPC_REQUEST', paste('unsupported target view command:', command), 'target_view_worker', .ark_target_view_session))",
    "}",
    ".ark_stdin <- file('stdin', open = 'r')",
    "repeat {",
    "  .ark_line <- readLines(.ark_stdin, n = 1L, warn = FALSE)",
    "  if (length(.ark_line) == 0L) break",
    "  if (!nzchar(.ark_line[[1L]])) next",
    "  .ark_req <- tryCatch(jsonlite::fromJSON(.ark_line[[1L]], simplifyVector = FALSE), error = function(e) e)",
    "  if (inherits(.ark_req, 'error')) {",
    "    .ark_worker_error('', conditionMessage(.ark_req), 'E_IPC_DECODE')",
    "    next",
    "  }",
    "  .ark_request_id <- .ark_req$request_id %||% ''",
    "  if (identical(.ark_req$command %||% '', 'shutdown')) break",
    "  .ark_json <- tryCatch(.ark_worker_payload(.ark_req), error = function(e) .emit_json(.new_error_payload('E_TARGET_VIEW', conditionMessage(e), 'target_view_worker', .ark_target_view_session)))",
    "  .ark_payload <- tryCatch(jsonlite::fromJSON(.ark_json, simplifyVector = FALSE), error = function(e) .new_error_payload('E_TARGET_VIEW', conditionMessage(e), 'target_view_worker', .ark_target_view_session))",
    "  .ark_worker_emit(.ark_request_id, .ark_payload)",
    "}",
  }
end

local Worker = {}
Worker.__index = Worker

local function new_request_id()
  next_request_id = next_request_id + 1
  return string.format("target-view-%d-%d", uv.os_getpid(), next_request_id)
end

local function notify(opts, message, level)
  local fn = opts and opts.notify or vim.notify
  fn(message, level or vim.log.levels.WARN, { title = "ark.nvim" })
end

function Worker:start()
  if self.job_id then
    return true
  end

  local r = self.r or vim.env.R_BINARY or "R"
  local script = vim.fn.tempname() .. ".R"
  local ok, err = pcall(vim.fn.writefile, worker_script_lines(self.session_id), script, "b")
  if not ok then
    return nil, "failed to write target ArkView worker script: " .. tostring(err)
  end

  local stdout = ""
  self.script = script
  self.job_id = vim.fn.jobstart({ r, "--slave", "--vanilla", "-f", script }, {
    stdin = "pipe",
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if type(data) ~= "table" then
        return
      end
      for index, chunk in ipairs(data) do
        if chunk ~= "" then
          if index == 1 then
            chunk = stdout .. chunk
            stdout = ""
          end
          if index == #data then
            stdout = chunk
          else
            self:handle_line(chunk)
          end
        elseif index == #data and stdout ~= "" then
          self:handle_line(stdout)
          stdout = ""
        end
      end
    end,
    on_stderr = function(_, data)
      if type(data) ~= "table" then
        return
      end
      for _, chunk in ipairs(data) do
        if chunk ~= "" then
          self.stderr[#self.stderr + 1] = chunk
        end
      end
    end,
    on_exit = function(_, code)
      self.exited = true
      self.exit_code = code
      if self.script then
        pcall(vim.fn.delete, self.script)
        self.script = nil
      end
    end,
  })

  if type(self.job_id) ~= "number" or self.job_id <= 0 then
    self.job_id = nil
    pcall(vim.fn.delete, script)
    return nil, "failed to start target ArkView R worker"
  end

  return true
end

function Worker:handle_line(line)
  local ok, decoded = pcall(vim.json.decode, line)
  if not ok or type(decoded) ~= "table" then
    self.stderr[#self.stderr + 1] = line
    return
  end

  local request_id = decoded.request_id
  if type(request_id) ~= "string" or request_id == "" then
    self.stderr[#self.stderr + 1] = line
    return
  end

  self.responses[request_id] = decoded
end

function Worker:request(command, payload, timeout_ms)
  local started, start_err = self:start()
  if not started then
    return nil, start_err
  end

  local request_id = new_request_id()
  payload = vim.tbl_extend("force", payload or {}, {
    command = command,
    request_id = request_id,
  })

  local sent = vim.fn.chansend(self.job_id, vim.json.encode(payload) .. "\n")
  if sent == 0 then
    return nil, "failed to send target ArkView request"
  end

  timeout_ms = timeout_ms or 12000
  local ready = vim.wait(timeout_ms, function()
    return self.responses[request_id] ~= nil or self.exited == true
  end, 10, false)

  local response = self.responses[request_id]
  self.responses[request_id] = nil
  if not ready or response == nil then
    local suffix = #self.stderr > 0 and (": " .. table.concat(self.stderr, "\n")) or ""
    return nil, "target ArkView request timed out" .. suffix
  end

  if type(response.error) == "table" then
    return nil, tostring(response.error.message or "target ArkView request failed")
  end

  response.request_id = nil
  return response, nil
end

function Worker:stop()
  if self.stopped then
    return
  end
  self.stopped = true

  if self.job_id then
    pcall(vim.fn.chansend, self.job_id, vim.json.encode({
      command = "shutdown",
      request_id = new_request_id(),
    }) .. "\n")
    pcall(vim.fn.jobstop, self.job_id)
  end
  if self.script then
    pcall(vim.fn.delete, self.script)
    self.script = nil
  end
end

local function target_expr(name)
  return "targets::tar_read(name = " .. r_string_literal(name) .. ")"
end

function M.create(opts)
  opts = opts or {}
  local project = opts.project or {}
  local name = opts.name
  local worker = setmetatable({
    name = name,
    project = project,
    r = opts.r,
    responses = {},
    stderr = {},
    session_id = string.format("target-view-%d-%d", uv.os_getpid(), math.floor(uv.hrtime() / 1000000)),
  }, Worker)

  local proxy = {}
  local root_session_id = nil

  proxy.view_open = function()
    local opened, err = worker:request("targets_view_open", {
      root = project.root or "",
      script = project.script or "",
      store = project.store or "",
      name = name or "",
    })
    if type(opened) == "table" and type(opened.session_id) == "string" then
      root_session_id = opened.session_id
    end
    return opened, err
  end

  proxy.view_state = function(_, _, session_id)
    return worker:request("view_state", { session_id = session_id or "" })
  end

  proxy.view_page = function(_, _, session_id, offset, limit, columns)
    return worker:request("view_page", {
      session_id = session_id or "",
      offset = offset or 0,
      limit = limit or 0,
      columns = columns or {},
    })
  end

  proxy.view_sort = function(_, _, session_id, column_index, direction)
    return worker:request("view_sort", {
      session_id = session_id or "",
      column_index = column_index or 0,
      direction = direction or "",
    })
  end

  proxy.view_filter = function(_, _, session_id, column_index, query, mode, value_key, label)
    return worker:request("view_filter", {
      session_id = session_id or "",
      column_index = column_index or 0,
      query = query or "",
      mode = mode or "contains",
      value_key = value_key or "",
      label = label or "",
    })
  end

  proxy.view_values = function(_, _, session_id, column_index)
    return worker:request("view_values", {
      session_id = session_id or "",
      column_index = column_index or 0,
    })
  end

  proxy.view_schema_search = function(_, _, session_id, query)
    return worker:request("view_schema_search", {
      session_id = session_id or "",
      query = query or "",
    })
  end

  proxy.view_profile = function(_, _, session_id, column_index)
    return worker:request("view_profile", {
      session_id = session_id or "",
      column_index = column_index or 0,
    })
  end

  proxy.view_code = function(_, _, session_id)
    return worker:request("view_code", { session_id = session_id or "" })
  end

  proxy.view_export = function(_, _, session_id, format)
    return worker:request("view_export", {
      session_id = session_id or "",
      format = format or "tsv",
    })
  end

  proxy.view_cell = function(_, _, session_id, row_index, column_index)
    return worker:request("view_cell", {
      session_id = session_id or "",
      row_index = row_index or 0,
      column_index = column_index or 0,
    })
  end

  proxy.view_close = function(_, _, session_id)
    local result, err = worker:request("view_close", { session_id = session_id or "" }, 3000)
    if root_session_id == nil or session_id == root_session_id then
      worker:stop()
    end
    return result, err
  end

  proxy.object_children = function(_, _, session_id, node_id, offset, limit)
    return worker:request("object_children", {
      session_id = session_id or "",
      node_id = node_id or "",
      offset = offset or 0,
      limit = limit or 0,
    })
  end

  proxy.object_detail = function(_, _, session_id, node_id)
    return worker:request("object_detail", {
      session_id = session_id or "",
      node_id = node_id or "",
    })
  end

  proxy.object_table = function(_, _, session_id, node_id)
    return worker:request("object_table", {
      session_id = session_id or "",
      node_id = node_id or "",
    })
  end

  proxy.object_search = function(_, _, session_id, query, max_nodes, max_results)
    return worker:request("object_search", {
      session_id = session_id or "",
      query = query or "",
      max_nodes = max_nodes or 1000,
      max_results = max_results or 100,
    })
  end

  return {
    expr = target_expr(name),
    lsp = proxy,
    stop = function()
      worker:stop()
    end,
  }
end

function M.open(opts)
  opts = opts or {}
  local backend = M.create(opts)
  local opened, err = require("ark.view").open({
    expr = backend.expr,
    source_bufnr = opts.source_bufnr,
    options = opts.options or {},
    lsp = backend.lsp,
    notify = function(message, level)
      notify(opts, message, level)
    end,
    on_close = backend.stop,
  })

  if not opened then
    backend.stop()
  end

  return opened, err
end

return M
