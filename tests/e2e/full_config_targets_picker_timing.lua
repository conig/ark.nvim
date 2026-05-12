local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(30000, "full_config_targets_picker_timing")

local tmp = vim.fn.tempname()
local picker_spec = nil
local original_pick = nil

local ok, err = xpcall(function()
  vim.fn.mkdir(tmp, "p")
  vim.fn.mkdir(tmp .. "/_target_pipelines", "p")
  vim.fn.writefile({
    "source('_target_pipelines/report.R')",
    "targets::tar_target(clean_data, clean(raw_data))",
    "targets::tar_target(model, fit_model(clean_data))",
  }, tmp .. "/_targets.R")
  vim.fn.writefile({
    "tarchetypes::tar_render(report, 'report.Rmd')",
  }, tmp .. "/_target_pipelines/report.R")

  vim.cmd("edit " .. vim.fn.fnameescape(tmp .. "/_targets.R"))
  vim.bo.filetype = "r"

  local ark = require("ark")
  local ok_snacks, snacks = pcall(require, "snacks")
  if not ok_snacks or type(snacks) ~= "table" or type(snacks.picker) ~= "table" then
    ark_test.fail("snacks.nvim is required for the real-config target picker timing test")
  end

  original_pick = snacks.picker.pick
  snacks.picker.pick = function(spec)
    picker_spec = spec
  end

  local started = vim.loop.hrtime()
  local opened, pick_err = ark.targets_pick(0)
  local elapsed_ms = math.floor((vim.loop.hrtime() - started) / 1e6)

  if not opened then
    ark_test.fail("target picker failed: " .. tostring(pick_err))
  end
  if elapsed_ms >= 1000 then
    ark_test.fail("real-config target picker list took " .. elapsed_ms .. "ms")
  end
  if picker_spec == nil then
    ark_test.fail("expected Ark target picker to open Snacks under the real config")
  end
  if picker_spec.preview ~= "preview" then
    ark_test.fail("expected real-config target picker to use preview panes")
  end
  if type(picker_spec.items) ~= "table" or #picker_spec.items ~= 3 then
    ark_test.fail("expected three real-config target picker items, got " .. vim.inspect(picker_spec.items))
  end

  vim.print({
    elapsed_ms = elapsed_ms,
    targets = vim.tbl_map(function(item)
      return item.name
    end, picker_spec.items),
  })

  pcall(ark.stop_pane)
end, debug.traceback)

if original_pick ~= nil then
  local ok_snacks, snacks = pcall(require, "snacks")
  if ok_snacks and type(snacks) == "table" and type(snacks.picker) == "table" then
    snacks.picker.pick = original_pick
  end
end
vim.fn.delete(tmp, "rf")

stop_watchdog()
if not ok then
  error(err, 0)
end
