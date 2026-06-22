vim.opt.rtp:prepend(vim.fn.getcwd())

local target_tools = require("ark.targets")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.fn.mkdir(tmp .. "/_target_pipelines", "p")

local targets_file = tmp .. "/_targets.R"
local pipeline_file = tmp .. "/_target_pipelines/extra.R"
vim.fn.writefile({
  "targets::tar_source('_target_pipelines')",
  "targets::tar_target(initial_target, 1)",
}, targets_file)

local project = {
  root = tmp,
  script = targets_file,
  store = tmp .. "/_targets",
}

local function target_names(payload)
  local names = {}
  for _, target in ipairs(payload.targets or {}) do
    names[#names + 1] = target.name
  end
  table.sort(names)
  return names
end

local function contains(values, expected)
  for _, value in ipairs(values) do
    if value == expected then
      return true
    end
  end
  return false
end

local first = target_tools.static_manifest(project)
local first_names = target_names(first)
if not contains(first_names, "initial_target") then
  error("initial manifest did not include initial_target: " .. vim.inspect(first), 0)
end

local original_readfile = vim.fn.readfile
vim.fn.readfile = function(...)
  error("static manifest cache missed and reread source files", 0)
end

local ok_cached, cached = pcall(target_tools.static_manifest, project)
vim.fn.readfile = original_readfile
if not ok_cached then
  vim.fn.delete(tmp, "rf")
  error(cached, 0)
end
if not vim.deep_equal(first_names, target_names(cached)) then
  vim.fn.delete(tmp, "rf")
  error("cached manifest changed target names: " .. vim.inspect(cached), 0)
end

vim.fn.writefile({
  "tarchetypes::tar_render(report_target, 'report.Rmd')",
}, pipeline_file)

local after_new_file = target_tools.static_manifest(project)
local after_new_file_names = target_names(after_new_file)
if not contains(after_new_file_names, "report_target") then
  vim.fn.delete(tmp, "rf")
  error("manifest cache did not invalidate after sourced directory changed: " .. vim.inspect(after_new_file), 0)
end

vim.fn.writefile({
  "targets::tar_source('_target_pipelines')",
  "targets::tar_target(renamed_target_with_longer_name, 1)",
}, targets_file)

local after_edit = target_tools.static_manifest(project)
local after_edit_names = target_names(after_edit)
if contains(after_edit_names, "initial_target") or not contains(after_edit_names, "renamed_target_with_longer_name") then
  vim.fn.delete(tmp, "rf")
  error("manifest cache did not invalidate after _targets.R changed: " .. vim.inspect(after_edit), 0)
end

vim.print({
  cached_elapsed_ms = cached.elapsed_ms,
  final_targets = after_edit_names,
})

vim.fn.delete(tmp, "rf")
