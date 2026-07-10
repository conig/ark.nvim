vim.opt.rtp:prepend(vim.fn.getcwd())

local test = require("tests.e2e.ark_test")

package.loaded["ark.lsp"] = nil
package.loaded["ark.session"] = {}

local bufnr = vim.api.nvim_get_current_buf()
vim.bo[bufnr].filetype = "r"

local requests = 0
local client = {
  id = 94,
  name = "ark_lsp",
  initialized = true,
  is_stopped = function()
    return false
  end,
  request_sync = function(_, method)
    if method ~= "ark/internal/helpText" then
      test.fail("unexpected request: " .. tostring(method))
    end

    requests = requests + 1
    if requests == 1 then
      return {
        err = {
          code = -32801,
          message = "request result is stale because the session changed",
        },
      }, nil
    end

    return {
      result = {
        topic = "lm",
        text = "Fitting Linear Models",
        references = {},
      },
    }, nil
  end,
}

local original_get_clients = vim.lsp.get_clients
local original_buf_is_attached = vim.lsp.buf_is_attached

vim.lsp.get_clients = function(filter)
  if type(filter) == "table" and filter.name and filter.name ~= client.name then
    return {}
  end
  return { client }
end

vim.lsp.buf_is_attached = function(candidate_bufnr, client_id)
  return candidate_bufnr == bufnr and client_id == client.id
end

local ok, err = pcall(function()
  -- Reproduce the R help-hook race: returning to the prompt advances repl_seq
  -- while the first help request is in flight, so Ark rejects that snapshot
  -- with ContentModified and the client must retry against the current session.
  local page, page_err = require("ark.lsp").help_text({
    filetypes = { "r" },
    lsp = { name = "ark_lsp" },
  }, bufnr, "lm")

  if not page or page_err ~= nil or page.text ~= "Fitting Linear Models" then
    test.fail("help request did not recover from ContentModified: " .. vim.inspect({ page = page, err = page_err }))
  end
  if requests ~= 2 then
    test.fail("expected one bounded ContentModified retry, got " .. tostring(requests) .. " requests")
  end
end)

vim.lsp.get_clients = original_get_clients
vim.lsp.buf_is_attached = original_buf_is_attached
package.loaded["ark.lsp"] = nil
package.loaded["ark.session"] = nil

if not ok then
  error(err, 0)
end
