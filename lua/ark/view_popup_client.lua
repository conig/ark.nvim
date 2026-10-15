local M = {}
local pending = {}
local channels = {}
local sequence = 0

function M.complete(id, result, err)
  local callback = pending[id]
  pending[id] = nil
  if callback then
    if err == vim.NIL then
      err = nil
    end
    if result == vim.NIL then
      result = nil
    end
    callback(result, err)
  end
end

function M.request_async(chan, backend_id, method, args, callback)
  -- One small handshake per connection. The response channel belongs to the
  -- existing RPC connection; no listener, polling process, or extra socket.
  if not channels[chan] then
    local ok, info = pcall(vim.rpcrequest, chan, "nvim_get_api_info")
    if not ok then
      callback(nil, tostring(info))
      return nil, tostring(info)
    end
    channels[chan] = info[1]
  end
  sequence = sequence + 1
  local id = sequence
  pending[id] = callback
  local source = "require('ark.view_popup_backend').dispatch_async(...)"
  local ok = pcall(vim.rpcnotify, chan, "nvim_exec_lua", source, { backend_id, method, args, channels[chan], id })
  if not ok then
    M.complete(id, nil, "ArkView popup RPC send failed")
    return nil, "ArkView popup RPC send failed"
  end
  local function cancel()
    if not pending[id] then
      return
    end
    pending[id] = nil
    pcall(vim.rpcnotify, chan, "nvim_exec_lua", "require('ark.view_popup_backend').cancel(...)", { backend_id, id })
  end
  vim.defer_fn(function()
    local cb = pending[id]
    if not cb then
      return
    end
    cancel()
    cb(nil, "ArkView value request timed out (R may still be computing)")
  end, 12000)
  return true, nil, cancel
end

return M
