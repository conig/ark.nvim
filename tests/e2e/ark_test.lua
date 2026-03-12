local M = {}

function M.fail(message)
  error(message, 0)
end

function M.wait_for(label, timeout_ms, predicate)
  local ok = vim.wait(timeout_ms, predicate, 100, false)
  if not ok then
    M.fail("timed out waiting for " .. label)
  end
end

function M.tmux(args)
  local output = vim.fn.system(vim.list_extend({ "tmux" }, args))
  if vim.v.shell_error ~= 0 then
    M.fail("tmux command failed: " .. output)
  end
  return output
end

function M.request(client, method, params, timeout_ms)
  local response, err = client:request_sync(method, params, timeout_ms or 10000, 0)
  if err then
    M.fail(method .. " error: " .. err)
  end
  if not response then
    M.fail("no response for " .. method)
  end
  if response.error then
    M.fail(method .. " error: " .. vim.inspect(response.error))
  end
  if response.err then
    M.fail(method .. " error: " .. vim.inspect(response.err))
  end
  return response.result
end

function M.completion_items(result)
  if type(result) ~= "table" then
    return {}
  end
  if vim.islist(result) then
    return result
  end
  return result.items or {}
end

function M.find_item(items, label)
  for _, item in ipairs(items) do
    if item.label == label then
      return item
    end
  end
  return nil
end

function M.item_labels(items)
  local out = {}
  for _, item in ipairs(items) do
    out[#out + 1] = item.label
  end
  return out
end

function M.insert_text(item)
  return item.insertText or item.insert_text
end

function M.setup_managed_buffer(test_file, lines)
  require("ark").setup({
    auto_start_pane = false,
    auto_start_lsp = false,
    async_startup = false,
    configure_slime = true,
  })

  vim.fn.writefile(lines, test_file)
  vim.cmd("edit " .. test_file)
  vim.cmd("setfiletype r")

  local pane_id, pane_err = require("ark").start_pane()
  if not pane_id then
    M.fail(pane_err or "managed pane id missing")
  end

  M.wait_for("ark bridge ready", 20000, function()
    return require("ark").status().bridge_ready == true
  end)

  require("ark").start_lsp(0)

  M.wait_for("ark lsp client", 15000, function()
    local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
    return client ~= nil and client.initialized == true and not client:is_stopped()
  end)

  M.wait_for("managed R repl ready", 10000, function()
    return require("ark").status().repl_ready == true
  end)

  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  return pane_id, client
end

function M.probe_data_table_available(pane_id, setup_cmd)
  M.tmux({
    "send-keys",
    "-t",
    pane_id,
    setup_cmd,
    "Enter",
    "ark_dt_available",
    "Enter",
  })

  M.wait_for("data.table availability probe", 10000, function()
    local capture = M.tmux({ "capture-pane", "-p", "-t", pane_id })
    return capture:find("%[1%] TRUE") ~= nil or capture:find("%[1%] FALSE") ~= nil
  end)

  local capture = M.tmux({ "capture-pane", "-p", "-t", pane_id })
  return capture:find("%[1%] TRUE") ~= nil
end

return M
