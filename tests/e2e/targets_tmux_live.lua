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
  "  targets::tar_target(report, paste(clean_data$value, collapse = ','))",
  ")",
}, root .. "/_targets.R")

local test_file = root .. "/analysis.R"
ark_test.setup_managed_buffer(test_file, {
  "targets::tar_read(clean_data)",
})

local ark = require("ark")

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
for _, name in ipairs({ "raw_data", "clean_data", "report" }) do
  if not names[name] then
    ark_test.fail("target manifest missing " .. name .. ": " .. vim.inspect(manifest))
  end
end

local action = ark.targets_action("make", "clean_data", 0)
if type(action) ~= "table" or action.status ~= "ok" or action.action ~= "make" then
  ark_test.fail("expected target make payload, got " .. vim.inspect(action))
end

local meta = ark.targets_meta("clean_data", 0)
if type(meta) ~= "table" or meta.status ~= "ok" or type(meta.meta) ~= "table" or #meta.meta == 0 then
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

local load = ark.targets_action("load", "clean_data", 0)
if type(load) ~= "table" or load.status ~= "ok" or load.action ~= "load" then
  ark_test.fail("expected target load payload, got " .. vim.inspect(load))
end

vim.print({
  manifest = "ok",
  make = action.names,
  meta = #meta.meta,
  object = classes,
  load = load.names,
})
