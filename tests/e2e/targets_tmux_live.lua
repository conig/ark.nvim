local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

if vim.fn.executable("R") ~= 1 then
  ark_test.fail("R is required for targets tmux live test")
end

local has_targets = vim.fn.system({ "Rscript", "-e", "cat(requireNamespace('targets', quietly = TRUE))" })
if vim.v.shell_error ~= 0 or has_targets:find("TRUE", 1, true) == nil then
  ark_test.fail("targets package is required for targets tmux live test")
end

local root = vim.fs.normalize(ark_test.run_tmpdir() .. "/targets-tmux-live")
vim.fn.mkdir(root, "p")

local function rebuild_bridge_runtime()
  local bridge = require("ark.bridge")
  local config = require("ark.config").defaults().tmux
  local completed = nil
  local ok, build_err = bridge.build_session_runtime(config, {
    on_complete = function(result)
      completed = result
    end,
  })
  if not ok then
    ark_test.fail("failed to rebuild pane-side arkbridge runtime: " .. vim.inspect(build_err))
  end

  local ready = vim.wait(30000, function()
    return type(completed) == "table"
  end, 50, false)
  if not ready or completed.ok ~= true then
    ark_test.fail("timed out rebuilding pane-side arkbridge runtime: " .. vim.inspect(completed))
  end
end

rebuild_bridge_runtime()

vim.fn.writefile({
  "targets::tar_config_set(store = 'cache/targets')",
  "list(",
  "  targets::tar_target(raw_data, data.frame(id = 1:3, value = c('a', 'b', 'c'))),",
  "  targets::tar_target(clean_data, raw_data),",
  "  targets::tar_target(dt_data, data.table::data.table(dt_id = 1:3, dt_value = c('x', 'y', 'z'))),",
  "  targets::tar_target(list_data, list(alpha = 1, beta = 'two')),",
  "  targets::tar_target(report, paste(clean_data$value, collapse = ','))",
  ")",
}, root .. "/_targets.R")

local test_file = root .. "/analysis.R"
local pane_id, client = ark_test.setup_managed_buffer(test_file, {
  "targets::tar_read(clean_data)$",
  "targets::tar_read(dt_data)$",
  "targets::tar_read(list_data)$",
  "clean_data <- tar_read(clean_data)",
  'clean_data[["',
})

local ark = require("ark")

ark_test.tmux({
  "send-keys",
  "-t",
  pane_id,
  string.format("setwd(%q); getwd()", root),
  "Enter",
})
ark_test.wait_for("managed R project working directory", 10000, function()
  local capture = ark_test.tmux({ "capture-pane", "-p", "-t", pane_id })
  return capture:find(root, 1, true) ~= nil
end)

local function target_names(records)
  local names = {}
  for _, record in ipairs(records or {}) do
    names[record.name] = true
  end
  return names
end

local manifest = ark.targets_manifest(0)
if type(manifest) ~= "table" or manifest.status ~= "ok" then
  ark_test.fail("expected target manifest payload, got " .. vim.inspect(manifest))
end
local names = target_names(manifest.targets)
for _, name in ipairs({ "raw_data", "clean_data", "dt_data", "list_data", "report" }) do
  if not names[name] then
    ark_test.fail("target manifest missing " .. name .. ": " .. vim.inspect(manifest))
  end
end

local action = ark.targets_action("make", "clean_data, dt_data, list_data", 0)
if type(action) ~= "table" or action.status ~= "ok" or action.action ~= "make" then
  ark_test.fail("expected target make payload, got " .. vim.inspect(action))
end

local meta = ark.targets_meta("clean_data, dt_data, list_data", 0)
if type(meta) ~= "table" or meta.status ~= "ok" or type(meta.meta) ~= "table" or #meta.meta < 3 then
  ark_test.fail("expected target metadata payload, got " .. vim.inspect(meta))
end

local object = ark.targets_object_meta("clean_data", 0)
if type(object) ~= "table" or object.status ~= "ok" then
  ark_test.fail("expected target object metadata payload, got " .. vim.inspect(object))
end
local object_meta = object.object_meta or object.objectMeta or {}
local nested_meta = object_meta.object_meta or object_meta.objectMeta or object_meta
local classes = nested_meta.class or {}
if type(classes) == "string" then
  classes = { classes }
end
if not vim.tbl_contains(classes, "data.frame") then
  ark_test.fail("expected clean_data object metadata to include data.frame, got " .. vim.inspect(object))
end

local dt_object = ark.targets_object_meta("dt_data", 0)
if type(dt_object) ~= "table" or dt_object.status ~= "ok" then
  ark_test.fail("expected data.table target object metadata payload, got " .. vim.inspect(dt_object))
end
local dt_object_meta = dt_object.object_meta or dt_object.objectMeta or {}
local dt_nested_meta = dt_object_meta.object_meta or dt_object_meta.objectMeta or dt_object_meta
local dt_classes = dt_nested_meta.class or {}
if type(dt_classes) == "string" then
  dt_classes = { dt_classes }
end
if not vim.tbl_contains(dt_classes, "data.table") then
  ark_test.fail("expected dt_data object metadata to include data.table, got " .. vim.inspect(dt_object))
end

local list_object = ark.targets_object_meta("list_data", 0)
if type(list_object) ~= "table" or list_object.status ~= "ok" then
  ark_test.fail("expected list target object metadata payload, got " .. vim.inspect(list_object))
end
local list_object_meta = list_object.object_meta or list_object.objectMeta or {}
local list_nested_meta = list_object_meta.object_meta or list_object_meta.objectMeta or list_object_meta
if list_nested_meta.type ~= "list" then
  ark_test.fail("expected list_data object metadata to report list type, got " .. vim.inspect(list_object))
end

local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local function completion_at(line, trigger)
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = line - 1, character = #lines[line] },
  }
  if trigger then
    params.context = {
      triggerKind = vim.lsp.protocol.CompletionTriggerKind.TriggerCharacter,
      triggerCharacter = trigger,
    }
  end
  return ark_test.completion_items(ark_test.request(client, "textDocument/completion", params, 10000))
end

local direct_items = completion_at(1, "$")
if not ark_test.find_item(direct_items, "id") or not ark_test.find_item(direct_items, "value") then
  ark_test.fail("direct tar_read extractor completion missing target columns: " .. vim.inspect(ark_test.item_labels(direct_items)))
end

local dt_items = completion_at(2, "$")
if not ark_test.find_item(dt_items, "dt_id") or not ark_test.find_item(dt_items, "dt_value") then
  ark_test.fail("data.table tar_read extractor completion missing target columns: " .. vim.inspect(ark_test.item_labels(dt_items)))
end

local list_items = completion_at(3, "$")
if not ark_test.find_item(list_items, "alpha") or not ark_test.find_item(list_items, "beta") then
  ark_test.fail("list tar_read extractor completion missing target members: " .. vim.inspect(ark_test.item_labels(list_items)))
end

local assigned_items = completion_at(5, '"')
if not ark_test.find_item(assigned_items, "id") or not ark_test.find_item(assigned_items, "value") then
  ark_test.fail("assigned tar_read subset completion missing target columns: " .. vim.inspect(ark_test.item_labels(assigned_items)))
end

local load = ark.targets_action("load", "clean_data", 0)
if type(load) ~= "table" or load.status ~= "ok" or load.action ~= "load" then
  ark_test.fail("expected target load payload, got " .. vim.inspect(load))
end

local downstream = ark.targets_action("make_downstream", "raw_data", 0)
if type(downstream) ~= "table" or downstream.status ~= "ok" or downstream.action ~= "make_downstream" then
  ark_test.fail("expected target downstream make payload, got " .. vim.inspect(downstream))
end

local invalidate = ark.targets_action("invalidate", "report", 0)
if type(invalidate) ~= "table" or invalidate.status ~= "ok" or invalidate.action ~= "invalidate" then
  ark_test.fail("expected target invalidate payload, got " .. vim.inspect(invalidate))
end

vim.print({
  manifest = "ok",
  make = action.names,
  meta = #meta.meta,
  object = classes,
  data_table_object = dt_classes,
  list_object = list_nested_meta.type,
  direct_completion = ark_test.item_labels(direct_items),
  data_table_completion = ark_test.item_labels(dt_items),
  list_completion = ark_test.item_labels(list_items),
  assigned_completion = ark_test.item_labels(assigned_items),
  load = load.names,
  downstream = downstream.names,
  invalidate = invalidate.names,
})
