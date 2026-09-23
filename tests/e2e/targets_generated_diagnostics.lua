local ark_test = require("ark_test")

-- Real generated names, not copied from a user's pipeline. Nested maps and a
-- separately assigned template must be evaluated by targets, not guessed by
-- concatenating tokens in the static indexer.
local root = vim.fs.normalize(ark_test.run_tmpdir() .. "/generated-target-diagnostics")
vim.fn.mkdir(root .. "/_target_pipelines", "p")
vim.fn.mkdir(root .. "/.git", "p")
local source = root .. "/_target_pipelines/measurements.R"
vim.fn.writefile({
  'targets::tar_source("_target_pipelines")',
  'c(generated, targets::tar_target(anchor, 1))',
}, root .. "/_targets.R")
local function pipeline(sites)
  return {
    'template <- tarchetypes::tar_map(',
    '  data.frame(metric = c("height", "width")),',
    '  targets::tar_target(measurement, metric), names = metric)',
    'generated <- tarchetypes::tar_map(',
    '  data.frame(site = c(' .. sites .. ')), template, names = site)',
  }
end
vim.fn.writefile(pipeline('"forest", "meadow"'), source)

local _, client = ark_test.setup_managed_buffer(root .. "/report.R", {
  'targets::tar_read(measurement_height_forest)',
  'targets::tar_read("measurement_width_meadow")',
  'targets::tar_read(measurement_height_desert)',
  'targets::tar_read(measurement)', -- A template name, not a real manifest target.
  'undefined_sentinel',
})
local report = vim.api.nvim_get_current_buf()

local function messages()
  local result = {}
  for _, diagnostic in ipairs(vim.diagnostic.get(report)) do
    result[diagnostic.message] = true
  end
  return result
end
local function missing(name)
  return "No targets target named '" .. name .. "'."
end
local function await_diagnostics(label, predicate)
  local ok = vim.wait(20000, function() return predicate(messages()) end, 100)
  if not ok then
    error(label .. ": " .. vim.inspect(messages()), 0)
  end
end

-- The manifest RPC already enumerates these names. Diagnostics must consume
-- graph truth too, rather than blanket-disabling all missing-target warnings.
local manifest = require("ark").targets_manifest(report)
assert(manifest and manifest.source == "targets", vim.inspect(manifest))
local names = {}
for _, target in ipairs(manifest.targets) do names[target.name] = true end
assert(names.measurement_height_forest and names.measurement_width_meadow, vim.inspect(names))
assert(not names.measurement and not names.measurement_height_desert, vim.inspect(names))

await_diagnostics("generated graph diagnostics", function(found)
  return found[missing("measurement_height_desert")]
    and found[missing("measurement")]
    and not found[missing("measurement_height_forest")]
    and not found[missing("measurement_width_meadow")]
    and found["No symbol named 'undefined_sentinel' in scope."]
end)

-- Save a source edit without editing report.R: stale diagnostics must refresh
-- and generated names must be replaced, not accumulated across manifests.
vim.cmd("edit " .. vim.fn.fnameescape(source))
vim.cmd("setfiletype r")
require("ark").start_lsp(0)
ark_test.wait_for("pipeline buffer attached to the report LSP", 10000, function()
  return vim.lsp.buf_is_attached(0, client.id)
end)
vim.api.nvim_buf_set_lines(0, 0, -1, false, pipeline('"desert", "meadow"'))
vim.cmd("write")
await_diagnostics("updated generated graph diagnostics", function(found)
  return found[missing("measurement_height_forest")]
    and found[missing("measurement")]
    and not found[missing("measurement_height_desert")]
    and not found[missing("measurement_width_meadow")]
end)

-- Unsaved inputs cannot be checked against an older disk manifest.
vim.api.nvim_buf_set_lines(0, 0, -1, false, pipeline('"forest", "meadow"'))
await_diagnostics("unsaved pipeline invalidates graph authority", function(found)
  return not found[missing("measurement_height_forest")]
    and not found[missing("measurement_height_desert")]
    and not found[missing("measurement")]
    and found["No symbol named 'undefined_sentinel' in scope."]
end)

-- Evaluation failure returns a partial static manifest. Do not treat it as a
-- complete graph, and recover automatically after the next valid source save.
vim.api.nvim_buf_set_lines(0, -1, -1, false, { 'stop("synthetic graph discovery failure")' })
vim.cmd("write")
manifest = require("ark").targets_manifest(report)
assert(manifest and manifest.source == "static", vim.inspect(manifest))
await_diagnostics("failed manifest is not authoritative", function(found)
  return not found[missing("measurement_height_forest")]
    and not found[missing("measurement_height_desert")]
    and not found[missing("measurement")]
end)
vim.api.nvim_buf_set_lines(0, 0, -1, false, pipeline('"forest", "meadow"'))
vim.cmd("write")
await_diagnostics("manifest recovery", function(found)
  return found[missing("measurement_height_desert")]
    and found[missing("measurement")]
    and not found[missing("measurement_height_forest")]
    and not found[missing("measurement_width_meadow")]
end)

vim.print({ targets_generated_diagnostics = "ok", diagnostics = messages(), client = client.id })
