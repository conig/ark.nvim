local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

local test_file = "/tmp/ark_detached_runtime_hides_stale_static.R"

local pane_id, client = ark_test.setup_managed_buffer(test_file, {
  "ark_phantom_doc <- 1",
  "ark_",
})

ark_test.tmux({
  "send-keys",
  "-t",
  pane_id,
  'rm(list = intersect(c("ark_phantom_doc", "ark_runtime_live"), ls(envir = .GlobalEnv)), envir = .GlobalEnv); ark_runtime_live <- 1; cat("ARK_RUNTIME_READY\\n")',
  "Enter",
})

ark_test.wait_for("runtime completion fixture", 10000, function()
  local capture = ark_test.tmux({ "capture-pane", "-p", "-t", pane_id })
  return capture:find("ARK_RUNTIME_READY", 1, true) ~= nil
end)

local function completion_at(line, column)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = column },
  }

  local result = ark_test.request(client, "textDocument/completion", params, 10000)
  return result, ark_test.completion_items(result)
end

local result, items = nil, {}
ark_test.wait_for("runtime-backed ark_ completion", 5000, function()
  result, items = completion_at(2, 4)
  return ark_test.find_item(items, "ark_runtime_live") ~= nil
end)

local runtime_item = ark_test.find_item(items, "ark_runtime_live")
if not runtime_item then
  ark_test.fail("runtime completion missing ark_runtime_live: " .. vim.inspect({
    result = result,
    labels = ark_test.item_labels(items),
    status = require("ark").status({ include_lsp = true }),
  }))
end

local phantom_item = ark_test.find_item(items, "ark_phantom_doc")
if phantom_item then
  ark_test.fail("stale document completion leaked into runtime-backed results: " .. vim.inspect({
    phantom = phantom_item,
    labels = ark_test.item_labels(items),
    status = require("ark").status({ include_lsp = true }),
  }))
end

vim.print({
  runtime = runtime_item.label,
  item_count = #items,
})
