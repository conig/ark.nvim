local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))

if vim.fn.executable("R") ~= 1 then
  ark_test.fail("R is required for targets tar_make store parity test")
end

local has_targets = vim.fn.system({ "Rscript", "-e", "cat(requireNamespace('targets', quietly = TRUE))" })
if vim.v.shell_error ~= 0 or has_targets:find("TRUE", 1, true) == nil then
  ark_test.fail("targets package is required for targets tar_make store parity test")
end

local root = vim.fs.normalize(ark_test.run_tmpdir() .. "/targets-tar-make-repl-store")
vim.fn.mkdir(root, "p")

local normal_root = vim.fs.normalize(ark_test.run_tmpdir() .. "/targets-normal-repl-store")
vim.fn.mkdir(normal_root, "p")

local targets_lines = {
  "targets::tar_config_set(store = 'cache/future')",
  "list(",
  "  targets::tar_target(probe, { dir.create('built', showWarnings = FALSE); writeLines('ok', 'built/probe.txt'); 'ok' })",
  ")",
}
vim.fn.writefile(targets_lines, root .. "/_targets.R")
vim.fn.writefile(targets_lines, normal_root .. "/_targets.R")

local normal_output = vim.fn.system({
  "Rscript",
  "-e",
  "setwd(commandArgs(TRUE)[[1]]); targets::tar_make(names = 'probe', callr_function = NULL); cat('normal_default=', dir.exists('_targets'), '\\n', sep = ''); cat('normal_future=', dir.exists('cache/future'), '\\n', sep = '')",
  normal_root,
})
if vim.v.shell_error ~= 0 then
  ark_test.fail("normal targets::tar_make() probe failed: " .. normal_output)
end
if not normal_output:find("normal_default=TRUE", 1, true) or not normal_output:find("normal_future=FALSE", 1, true) then
  ark_test.fail("normal targets::tar_make() did not establish expected first-run store semantics: " .. normal_output)
end

local test_file = root .. "/analysis.R"
ark_test.setup_managed_buffer(test_file, {
  "probe",
})

local ark = require("ark")
local info = ark.targets_project_info(0)
if type(info) ~= "table" or info.status ~= "ok" then
  ark_test.fail("expected target project info payload, got " .. vim.inspect(info))
end

local expected_store = vim.fs.normalize(root .. "/_targets")
if type(info.project) ~= "table" or info.project.store ~= expected_store then
  ark_test.fail("Ark should present the same initial target store as normal tar_make(): " .. vim.inspect(info))
end

local action = ark.targets_action("make", "probe", 0)
if type(action) ~= "table" or action.status ~= "ok" or action.action ~= "make" then
  ark_test.fail("expected target make payload, got " .. vim.inspect(action))
end

if type(action.project) ~= "table" or action.project.store ~= expected_store then
  ark_test.fail("Ark tar_make action should report the normal target store: " .. vim.inspect(action))
end

if vim.fn.isdirectory(root .. "/_targets") ~= 1 then
  ark_test.fail("Ark tar_make action did not build the normal _targets store: " .. vim.inspect(action))
end

if vim.fn.isdirectory(root .. "/cache/future") == 1 then
  ark_test.fail("Ark tar_make action built the future script-mutated store instead of the normal first-run store")
end
