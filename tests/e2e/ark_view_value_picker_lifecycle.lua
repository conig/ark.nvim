vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/snacks.nvim")
local snacks = require("snacks")
snacks.setup({ picker = { enabled = true } })
local notified
local picker = require("ark.value_picker").open({
  title = "Values lifecycle",
  fetch = function(_, callback)
    -- Disconnected backends may fail synchronously. Exercise the real Snacks
    -- finder so that failure is delivered without hanging or losing it.
    callback(nil, "bridge unavailable")
    return nil, "bridge unavailable"
  end,
  notify = function(message)
    notified = message
  end,
  choose = function()
    error("unexpected selection")
  end,
}, { total_values = 2000, values = { { label = "a", value_key = "a", count = 1 } } })
picker.input:set("", "query")
picker:find()
assert(
  vim.wait(2000, function()
    return notified ~= nil
  end, 10),
  "synchronous fetch error did not reach the picker"
)
assert(notified == "bridge unavailable", notified)
picker:close()
