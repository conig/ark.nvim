local ark_test = require("ark_test")
require("ark").setup({ auto_start_pane = false, auto_start_lsp = false })
local root = ark_test.run_tmpdir() .. "/lsp-request-burst"
vim.fn.mkdir(root, "p")
vim.cmd("edit " .. vim.fn.fnameescape(root .. "/main.R"))
vim.bo.filetype = "r"

local sent = false
local completed = 0
local errors = {}
local request_count = 256
local capabilities = vim.lsp.protocol.make_client_capabilities()
capabilities.workspace.configuration = true
capabilities.workspace.didChangeWatchedFiles = { dynamicRegistration = false }
local id = assert(vim.lsp.start({
  name = "ark_request_burst_test",
  cmd = { vim.env.ARK_NVIM_LSP_BIN or (vim.fn.getcwd() .. "/target/debug/ark-lsp"), "--runtime-mode", "detached" },
  cmd_env = { ARK_SESSION_STATUS_FILE = "", ARK_SESSION_PORT = "0", ARK_SESSION_AUTH_TOKEN = "" },
  root_dir = root,
  capabilities = capabilities,
  handlers = {
    ["workspace/configuration"] = function(err, params, ctx, config)
      local result = vim.lsp.handlers["workspace/configuration"](err, params, ctx, config)
      if not sent then
        sent = true
        local client = assert(vim.lsp.get_client_by_id(ctx.client_id))
        -- Upstream #1444: while the serial main loop awaits this configuration
        -- response, requests ahead of it must not saturate transport admission
        -- and prevent the socket reader from ever reaching the response.
        for _ = 1, request_count do
          assert(client:request("ark/internal/status", {}, function(request_err, status)
            completed = completed + 1
            if request_err or not status or status.runtimeMode ~= "detached" then
              errors[#errors + 1] = request_err or status or "missing status"
            end
          end))
        end
      end
      return result
    end,
  },
}))
ark_test.wait_for("initialized LSP", 10000, function()
  return vim.lsp.get_client_by_id(id).initialized
end)
assert(vim.lsp.get_client_by_id(id):notify("workspace/didChangeConfiguration", { settings = {} }))
ark_test.wait_for("configuration request to exercise response ordering", 10000, function() return sent end)
ark_test.wait_for("every queued request to complete without a transport deadlock", 10000, function()
  return completed == request_count
end)
assert(#errors == 0, vim.inspect(errors))
vim.lsp.get_client_by_id(id):stop(true)
print("all " .. request_count .. " requests completed ahead of the configuration response")
