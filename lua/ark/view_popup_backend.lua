local M = {}

local uv = vim.uv or vim.loop
local backends = {}
local next_id = 0
local global_rpc_name = "__ark_view_popup_backend"
local unpack_args = table.unpack or unpack

local view_methods = {
  view_cell = true,
  view_close = true,
  view_code = true,
  view_export = true,
  view_filter = true,
  view_values = true,
  view_open = true,
  view_page = true,
  view_profile = true,
  view_schema_search = true,
  view_sort = true,
  view_state = true,
}

local function new_id()
  next_id = next_id + 1
  local pid = uv and type(uv.os_getpid) == "function" and uv.os_getpid() or 0
  local now = uv and type(uv.hrtime) == "function" and uv.hrtime() or os.time()
  return string.format("ark-view-%s-%s-%s", tostring(pid), tostring(now), tostring(next_id))
end

local function rpc_response(ok, value, err)
  if ok then
    return {
      ok = true,
      value = value,
    }
  end

  return {
    ok = false,
    err = tostring(err or value or "ArkView popup backend request failed"),
  }
end

function M.unregister(id)
  if type(id) == "string" then
    backends[id] = nil
  end
end

function M.dispatch(id, method, args)
  if method == "dispose" then
    M.unregister(id)
    return rpc_response(true)
  end

  if not view_methods[method] then
    return rpc_response(false, nil, "unsupported ArkView popup backend method: " .. tostring(method))
  end

  local backend = backends[id]
  if type(backend) ~= "table" then
    return rpc_response(false, nil, "unknown ArkView popup backend: " .. tostring(id))
  end

  args = type(args) == "table" and args or {}
  local lsp = require("ark.lsp")
  local fn = lsp[method]
  if type(fn) ~= "function" then
    return rpc_response(false, nil, "ark.lsp does not implement " .. tostring(method))
  end

  local ok, result, err = pcall(fn, backend.options, backend.source_bufnr, unpack_args(args))
  if not ok then
    return rpc_response(false, nil, result)
  end
  if err then
    return rpc_response(false, nil, err)
  end

  return rpc_response(true, result)
end

function M.ensure_rpc()
  _G[global_rpc_name] = function(id, method, args)
    return M.dispatch(id, method, args)
  end
end

function M.register(opts)
  opts = opts or {}
  if type(opts.source_bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(opts.source_bufnr) then
    return nil, "ArkView popup backend requires a valid source buffer"
  end

  M.ensure_rpc()

  local id = new_id()
  backends[id] = {
    options = opts.options or {},
    source_bufnr = opts.source_bufnr,
  }

  return id, nil
end

function M.global_rpc_name()
  return global_rpc_name
end

return M
