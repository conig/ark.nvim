local uv = vim.uv or vim.loop

local M = {}

local METHODS = {
  help_text = "ark/internal/helpText",
  help_topic = "ark/textDocument/helpTopic",
  object_children = "ark/internal/objectChildren",
  object_detail = "ark/internal/objectDetail",
  object_search = "ark/internal/objectSearch",
  object_table = "ark/internal/objectTable",
  package_install = "ark/internal/packageInstall",
  targets_action = "ark/internal/targetsAction",
  targets_manifest = "ark/internal/targetsManifest",
  targets_meta = "ark/internal/targetsMeta",
  targets_network = "ark/internal/targetsNetwork",
  targets_object_meta = "ark/internal/targetsObjectMeta",
  targets_project_info = "ark/internal/targetsProjectInfo",
  targets_view_open = "ark/internal/targetsViewOpen",
  view_cell = "ark/internal/viewCell",
  view_close = "ark/internal/viewClose",
  view_code = "ark/internal/viewCode",
  view_export = "ark/internal/viewExport",
  view_filter = "ark/internal/viewFilter",
  view_open = "ark/internal/viewOpen",
  view_page = "ark/internal/viewPage",
  view_profile = "ark/internal/viewProfile",
  view_schema_search = "ark/internal/viewSchemaSearch",
  view_sort = "ark/internal/viewSort",
  view_state = "ark/internal/viewState",
  view_values = "ark/internal/viewValues",
}
local VIEW_REQUEST_TIMEOUT_MS = 12000

local function is_content_modified_error(err)
  if type(err) == "table" and err.code == -32801 then
    return true
  end
  return type(err) == "string" and err:find("stale because", 1, true) ~= nil
end

local function request_error_message(err)
  if err == nil then
    return nil
  end
  if type(err) == "string" then
    return err
  end
  if type(err) == "table" and type(err.message) == "string" then
    return err.message
  end
  return vim.inspect(err)
end

function M.new(deps)
  vim.validate({
    client_for_buffer = { deps.client_for_buffer, "function" },
    filetype_enabled = { deps.filetype_enabled, "function" },
    live_client = { deps.live_client, "function" },
    resolve_bufnr = { deps.resolve_bufnr, "function" },
  })

  local adapter = {}
  adapter.is_content_modified_error = is_content_modified_error

  function adapter.request(client, method, params, timeout_ms, bufnr)
    local timeout = timeout_ms or 5000
    local deadline = uv.hrtime() + timeout * 1e6

    while true do
      local remaining = math.max(1, math.floor((deadline - uv.hrtime()) / 1e6))
      local response, err = client:request_sync(method, params, remaining, bufnr or 0)
      if err then
        return nil, err
      end
      if not response then
        return nil, "no response"
      end

      local response_error = response.error or response.err
      if is_content_modified_error(response_error) and uv.hrtime() < deadline then
        vim.wait(10, function()
          return false
        end, 5, false)
      elseif response_error then
        return nil, vim.inspect(response_error)
      else
        return response.result, nil
      end
    end
  end

  function adapter.request_async(client, method, params, timeout_ms, bufnr, callback)
    local completed = false
    local request_id = nil

    local function finish(result, err)
      if completed then
        return
      end
      completed = true
      callback(result, err)
    end

    local ok, id = client:request(method, params or {}, function(err, result)
      if err then
        finish(nil, request_error_message(err))
        return
      end
      finish(result, nil)
    end, bufnr or 0)

    if not ok then
      finish(nil, "request failed")
      return nil, "request failed"
    end

    request_id = id
    if timeout_ms and timeout_ms > 0 then
      vim.defer_fn(function()
        if completed then
          return
        end
        if request_id and type(client.cancel_request) == "function" then
          client:cancel_request(request_id)
        end
        finish(nil, "timeout")
      end, timeout_ms)
    end

    return true
  end

  local function buffer_request(opts, bufnr, method, params, timeout_ms)
    bufnr = deps.resolve_bufnr(bufnr) or vim.api.nvim_get_current_buf()
    local client = deps.client_for_buffer(opts, bufnr)
    if not deps.live_client(client) then
      return nil, "ark_lsp client unavailable"
    end

    return adapter.request(client, method, params or {}, timeout_ms or 5000, bufnr)
  end

  local function buffer_request_async(opts, bufnr, method, params, timeout_ms, callback)
    bufnr = deps.resolve_bufnr(bufnr) or vim.api.nvim_get_current_buf()
    local client = deps.client_for_buffer(opts, bufnr)
    if not deps.live_client(client) then
      callback(nil, "ark_lsp client unavailable")
      return nil, "ark_lsp client unavailable"
    end

    return adapter.request_async(client, method, params or {}, timeout_ms or 5000, bufnr, callback)
  end

  function adapter.help_topic(opts, bufnr, position)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local current_filetype = vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype or nil
    if not deps.filetype_enabled(opts.filetypes, current_filetype) then
      return nil, "current buffer filetype is not managed by ark.nvim"
    end

    local target_position = position
    if type(target_position) ~= "table" then
      local cursor = vim.api.nvim_win_get_cursor(0)
      target_position = {
        line = cursor[1] - 1,
        character = cursor[2],
      }
    end

    local result, err = buffer_request(opts, bufnr, METHODS.help_topic, {
      textDocument = vim.lsp.util.make_text_document_params(bufnr),
      position = target_position,
    }, 1000)
    if err then
      return nil, err
    end
    if type(result) ~= "table" or type(result.topic) ~= "string" or result.topic == "" then
      return nil, "no help topic found"
    end
    return result.topic, nil
  end

  function adapter.help_text(opts, bufnr, topic)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local current_filetype = vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype or nil
    if not deps.filetype_enabled(opts.filetypes, current_filetype) then
      return nil, "current buffer filetype is not managed by ark.nvim"
    end
    if type(topic) ~= "string" or topic == "" then
      return nil, "missing help topic"
    end

    local result, err = buffer_request(opts, bufnr, METHODS.help_text, { topic = topic }, 3000)
    if err then
      return nil, err
    end
    if type(result) ~= "table" or type(result.text) ~= "string" or result.text == "" then
      return nil, "no help text found"
    end
    if not vim.islist(result.references) then
      result.references = {}
    end
    return result, nil
  end

  function adapter.view_open(opts, bufnr, expr)
    return buffer_request(opts, bufnr, METHODS.view_open, { expr = expr }, VIEW_REQUEST_TIMEOUT_MS)
  end

  function adapter.view_state(opts, bufnr, session_id)
    return buffer_request(opts, bufnr, METHODS.view_state, { sessionId = session_id }, VIEW_REQUEST_TIMEOUT_MS)
  end

  local function view_page_params(session_id, offset, limit, columns)
    local params = { sessionId = session_id, offset = offset or 0, limit = limit or 0 }
    if vim.islist(columns) and #columns > 0 then
      params.columns = columns
    end
    return params
  end

  function adapter.view_page(opts, bufnr, session_id, offset, limit, columns)
    return buffer_request(
      opts,
      bufnr,
      METHODS.view_page,
      view_page_params(session_id, offset, limit, columns),
      VIEW_REQUEST_TIMEOUT_MS
    )
  end

  function adapter.view_page_async(opts, bufnr, session_id, offset, limit, columns, callback)
    return buffer_request_async(
      opts,
      bufnr,
      METHODS.view_page,
      view_page_params(session_id, offset, limit, columns),
      VIEW_REQUEST_TIMEOUT_MS,
      callback
    )
  end

  function adapter.view_sort(opts, bufnr, session_id, column_index, direction)
    return buffer_request(opts, bufnr, METHODS.view_sort, {
      sessionId = session_id,
      columnIndex = column_index,
      direction = direction,
    }, VIEW_REQUEST_TIMEOUT_MS)
  end

  function adapter.view_filter(opts, bufnr, session_id, column_index, query, mode, value_key, label)
    return buffer_request(opts, bufnr, METHODS.view_filter, {
      sessionId = session_id,
      columnIndex = column_index,
      query = query,
      mode = mode or "contains",
      valueKey = value_key or "",
      label = label or "",
    }, VIEW_REQUEST_TIMEOUT_MS)
  end

  function adapter.view_values(opts, bufnr, session_id, column_index)
    return buffer_request(opts, bufnr, METHODS.view_values, {
      sessionId = session_id,
      columnIndex = column_index,
    }, VIEW_REQUEST_TIMEOUT_MS)
  end

  function adapter.view_schema_search(opts, bufnr, session_id, query)
    return buffer_request(opts, bufnr, METHODS.view_schema_search, {
      sessionId = session_id,
      query = query,
    }, VIEW_REQUEST_TIMEOUT_MS)
  end

  function adapter.view_profile(opts, bufnr, session_id, column_index)
    return buffer_request(opts, bufnr, METHODS.view_profile, {
      sessionId = session_id,
      columnIndex = column_index,
    }, VIEW_REQUEST_TIMEOUT_MS)
  end

  function adapter.view_code(opts, bufnr, session_id)
    return buffer_request(opts, bufnr, METHODS.view_code, { sessionId = session_id }, VIEW_REQUEST_TIMEOUT_MS)
  end

  function adapter.view_export(opts, bufnr, session_id, format)
    return buffer_request(opts, bufnr, METHODS.view_export, {
      sessionId = session_id,
      format = format or "tsv",
    }, VIEW_REQUEST_TIMEOUT_MS)
  end

  function adapter.view_cell(opts, bufnr, session_id, row_index, column_index)
    return buffer_request(opts, bufnr, METHODS.view_cell, {
      sessionId = session_id,
      rowIndex = row_index,
      columnIndex = column_index,
    }, VIEW_REQUEST_TIMEOUT_MS)
  end

  function adapter.view_close(opts, bufnr, session_id)
    return buffer_request(opts, bufnr, METHODS.view_close, { sessionId = session_id }, VIEW_REQUEST_TIMEOUT_MS)
  end

  function adapter.object_children(opts, bufnr, session_id, node_id, offset, limit)
    return buffer_request(opts, bufnr, METHODS.object_children, {
      sessionId = session_id,
      nodeId = node_id or "",
      offset = offset or 0,
      limit = limit or 0,
    }, VIEW_REQUEST_TIMEOUT_MS)
  end

  function adapter.object_detail(opts, bufnr, session_id, node_id)
    return buffer_request(opts, bufnr, METHODS.object_detail, {
      sessionId = session_id,
      nodeId = node_id or "",
    }, VIEW_REQUEST_TIMEOUT_MS)
  end

  function adapter.object_table(opts, bufnr, session_id, node_id)
    return buffer_request(opts, bufnr, METHODS.object_table, {
      sessionId = session_id,
      nodeId = node_id or "",
    }, VIEW_REQUEST_TIMEOUT_MS)
  end

  function adapter.object_search(opts, bufnr, session_id, query, max_nodes, max_results)
    return buffer_request(opts, bufnr, METHODS.object_search, {
      sessionId = session_id,
      query = query or "",
      maxNodes = max_nodes or 1000,
      maxResults = max_results or 100,
    }, VIEW_REQUEST_TIMEOUT_MS)
  end

  local function targets_project_payload(project)
    project = project or {}
    return { root = project.root or "", script = project.script or "", store = project.store or "" }
  end

  function adapter.targets_project_info(opts, bufnr, project)
    return buffer_request(opts, bufnr, METHODS.targets_project_info, targets_project_payload(project), 3000)
  end

  function adapter.targets_manifest(opts, bufnr, project)
    return buffer_request(opts, bufnr, METHODS.targets_manifest, targets_project_payload(project), 5000)
  end

  function adapter.targets_network(opts, bufnr, project)
    return buffer_request(opts, bufnr, METHODS.targets_network, targets_project_payload(project), 5000)
  end

  function adapter.targets_meta(opts, bufnr, project, names)
    local payload = targets_project_payload(project)
    payload.names = names or {}
    return buffer_request(opts, bufnr, METHODS.targets_meta, payload, 5000)
  end

  function adapter.targets_object_meta(opts, bufnr, project, name)
    local payload = targets_project_payload(project)
    payload.name = name or ""
    return buffer_request(opts, bufnr, METHODS.targets_object_meta, payload, 5000)
  end

  function adapter.targets_view_open(opts, bufnr, project, name)
    local payload = targets_project_payload(project)
    payload.name = name or ""
    return buffer_request(opts, bufnr, METHODS.targets_view_open, payload, VIEW_REQUEST_TIMEOUT_MS)
  end

  function adapter.targets_action(opts, bufnr, project, action, names)
    local payload = targets_project_payload(project)
    payload.action = action or ""
    payload.names = names or {}
    return buffer_request(opts, bufnr, METHODS.targets_action, payload, 120000)
  end

  function adapter.targets_action_async(opts, bufnr, project, action, names, callback)
    local payload = targets_project_payload(project)
    payload.action = action or ""
    payload.names = names or {}
    return buffer_request_async(opts, bufnr, METHODS.targets_action, payload, 120000, callback)
  end

  function adapter.package_install(opts, bufnr, packages, description, dry_run)
    return buffer_request(opts, bufnr, METHODS.package_install, {
      packages = packages or {},
      description = description or "",
      dryRun = dry_run == true,
    }, 600000)
  end

  function adapter.package_install_async(opts, bufnr, packages, description, dry_run, callback)
    return buffer_request_async(opts, bufnr, METHODS.package_install, {
      packages = packages or {},
      description = description or "",
      dryRun = dry_run == true,
    }, 600000, callback)
  end

  return adapter
end

return M
