local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local ok_blink, blink = pcall(require, "blink.cmp")
local list = ok_blink and require("blink.cmp.completion.list") or nil
local ok_trigger, trigger = pcall(require, "blink.cmp.completion.trigger")
local stop_watchdog = ark_test.start_watchdog(60000, "full_config_extractor_completion_timing")

local ok, err = xpcall(function()
  ark_test.wait_for("R filetype", 10000, function()
    return vim.bo.filetype == "r"
  end)

  ark_test.wait_for("ark bridge ready", 30000, function()
    local status = require("ark").status({ include_lsp = true })
    return status ~= nil and status.bridge_ready == true
  end)

  ark_test.wait_for("ark lsp hydrated", 30000, function()
    local status = require("ark").status({ include_lsp = true })
    local lsp_status = status and status.lsp_status or nil
    return lsp_status
      and lsp_status.available == true
      and tonumber(lsp_status.consoleScopeCount or 0) > 0
      and tonumber(lsp_status.libraryPathCount or 0) > 0
  end)

  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "mylist = list(x = 1, y = mtcars)",
    "mylist$",
  })
  vim.api.nvim_win_set_cursor(0, { 2, 7 })

  if not ok_blink or not ok_trigger or not blink or not trigger or not list then
    ark_test.fail("blink.cmp is required for this test")
  end

  blink.hide()
  trigger.show({
    trigger_kind = "trigger_character",
    trigger_character = "$",
  })

  vim.wait(500, function()
    return not blink.is_visible()
  end, 50, false)

  local labels = vim.tbl_map(function(item)
    return item.label
  end, list.items or {})

  if #labels ~= 0 then
    ark_test.fail("mylist$ should not surface stale static blink items: " .. vim.inspect(labels))
  end

  vim.print({
    labels = labels,
  })
end, debug.traceback)

stop_watchdog()
if not ok then
  error(err, 0)
end
