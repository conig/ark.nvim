vim.opt.rtp:prepend(vim.fn.getcwd())

local devine_root = vim.fs.normalize(vim.fn.expand("~/repos/devine"))
if vim.fn.isdirectory(devine_root) ~= 1 then
  vim.print({ skipped = "devine repo is not available" })
  return
end

if vim.fn.executable("Rscript") ~= 1 then
  vim.print({ skipped = "Rscript is not available" })
  return
end

local has_targets = vim.fn.system({ "Rscript", "-e", "cat(requireNamespace('targets', quietly = TRUE))" })
if vim.v.shell_error ~= 0 or has_targets:find("TRUE", 1, true) == nil then
  vim.print({ skipped = "targets package is not available" })
  return
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local function copy_path(relative)
  local source = devine_root .. "/" .. relative
  local target = tmp .. "/" .. relative
  vim.fn.mkdir(vim.fs.dirname(target), "p")
  local result = vim.fn.system({ "cp", "-a", source, target })
  if vim.v.shell_error ~= 0 then
    error("failed to copy " .. source .. ": " .. result, 0)
  end
end

copy_path("_targets.R")
copy_path("_target_pipelines")
copy_path("R")
copy_path("data")
copy_path("rmd")

local manifest_path = tmp .. "/manifest_names.txt"
local script = table.concat({
  "library(targets)",
  "m <- targets::tar_manifest(script = '_targets.R')",
  "writeLines(m$name, 'manifest_names.txt')",
}, "; ")
local manifest_cmd = string.format(
  "cd %s && dir_path=/tmp target_store_path=%s Rscript -e %s",
  vim.fn.shellescape(tmp),
  vim.fn.shellescape(tmp .. "/target-store"),
  vim.fn.shellescape(script)
)
local manifest_output = vim.fn.system(manifest_cmd)
if vim.v.shell_error ~= 0 then
  vim.fn.delete(tmp, "rf")
  error("failed to generate devine target manifest: " .. manifest_output, 0)
end

local expected = vim.fn.readfile(manifest_path)
local expected_set = {}
for _, name in ipairs(expected) do
  expected_set[name] = true
end

local target_tools = require("ark.targets")
local started = vim.loop.hrtime()
local manifest = target_tools.static_manifest({
  root = devine_root,
  script = devine_root .. "/_targets.R",
  store = devine_root .. "/_targets",
})
local elapsed_ms = math.floor((vim.loop.hrtime() - started) / 1e6)

local actual_set = {}
for _, record in ipairs(manifest.targets or {}) do
  actual_set[record.name] = true
end

local missing = {}
for name in pairs(expected_set) do
  if not actual_set[name] then
    missing[#missing + 1] = name
  end
end
table.sort(missing)

local extra = {}
for name in pairs(actual_set) do
  if not expected_set[name] then
    extra[#extra + 1] = name
  end
end
table.sort(extra)

if elapsed_ms >= 250 then
  error("devine fast target manifest should take <250ms, got " .. elapsed_ms .. "ms", 0)
end

if #missing ~= 0 or #extra ~= 0 then
  error(
    "devine fast target manifest mismatch: "
      .. vim.inspect({
        expected = #expected,
        actual = #(manifest.targets or {}),
        elapsed_ms = elapsed_ms,
        missing = vim.list_slice(missing, 1, 20),
        extra = vim.list_slice(extra, 1, 20),
      }),
    0
  )
end

local derived = nil
for _, record in ipairs(manifest.targets or {}) do
  if record.name:match("^model_.+_single$") then
    derived = record
    break
  end
end

if type(derived) ~= "table" or derived.generator_name ~= "model" then
  error("expected derived model target to retain generic generator provenance, got " .. vim.inspect(derived), 0)
end

vim.print({
  elapsed_ms = elapsed_ms,
  targets = #(manifest.targets or {}),
  derived = derived.name,
  generator = derived.generator_name,
})

vim.fn.delete(tmp, "rf")
