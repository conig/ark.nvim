local ark_test = require("ark_test")
local _, client = ark_test.setup_managed_buffer(ark_test.run_tmpdir() .. "/popup-values.R", { "" })
local opened =
  ark_test.request(client, "ark/internal/viewOpen", { expr = "data.table::as.data.table(maps::world.cities)" }, 10000)
local backend = require("ark.view_popup_backend")
local id =
  assert(backend.register({ options = require("ark").options(), source_bufnr = vim.api.nvim_get_current_buf() }))
local parent = vim.v.servername
if parent == "" then
  parent = vim.fn.serverstart("ark-test-values")
end
-- Real two-Neovim bidirectional RPC, with the parent serving a real LSP/R bridge.
-- No visible GUI and no polling/reverse-listener in the production transport.
local child = vim.fn.jobstart({ "nvim", "--embed", "--headless", "-u", "NONE", "-i", "NONE" }, { rpc = true })
assert(child > 0)
local ok, err = pcall(function()
  vim.rpcrequest(child, "nvim_exec_lua", "vim.opt.rtp:prepend(...)", { vim.fn.getcwd() })
  local started = vim.uv.hrtime()
  vim.rpcrequest(
    child,
    "nvim_exec_lua",
    [[
    local parent, backend_id, session_id = ...
    local chan = vim.fn.sockconnect("pipe", parent, { rpc = true })
    local client = require("ark.view_popup_client")
    client.request_async(chan, backend_id, "view_values", {session_id, 1, "Xianggangdao", 0, 1000}, function(result, err)
      _G.values_result, _G.values_error = result, err
    end)
  ]],
    { parent, id, opened.session_id }
  )
  assert((vim.uv.hrtime() - started) / 1e6 < 250, "popup request blocked on R")
  local result
  ark_test.wait_for("popup async response", 10000, function()
    result = vim.rpcrequest(child, "nvim_exec_lua", "return {result=_G.values_result, err=_G.values_error}", {})
    return result.result ~= nil or result.err ~= nil
  end)
  assert(not result.err, vim.inspect(result))
  assert(result.result.values[1].label == "Xianggangdao", vim.inspect(result))
  assert(#result.result.values == 1)
end)
backend.unregister(id)
vim.fn.jobstop(child)
assert(ok, err)
