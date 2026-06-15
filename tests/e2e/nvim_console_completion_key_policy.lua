vim.opt.rtp:prepend(vim.fn.getcwd())

local feedkeys_original = vim.api.nvim_feedkeys
local fed_keys
local fed_mode
local fed_escape_ks
vim.api.nvim_feedkeys = function(keys, mode, escape_ks)
  fed_keys = keys
  fed_mode = mode
  fed_escape_ks = escape_ks
end

local menu_visible = false
local snippet_direction
local select_and_accept_calls = 0
local accept_calls = 0
local cancel_calls = 0
local undo_preview_calls = 0
local trigger_hide_calls = 0
local menu_close_calls = 0
local snippet_forward_calls = 0
local snippet_backward_calls = 0

package.preload["blink.cmp.completion.list"] = function()
  return {
    undo_preview = function()
      undo_preview_calls = undo_preview_calls + 1
    end,
  }
end

package.preload["blink.cmp.completion.trigger"] = function()
  return {
    hide = function()
      trigger_hide_calls = trigger_hide_calls + 1
    end,
  }
end

package.preload["blink.cmp.completion.windows.menu"] = function()
  return {
    close = function()
      menu_close_calls = menu_close_calls + 1
    end,
  }
end

package.preload["blink.cmp"] = function()
  return {
    is_menu_visible = function()
      return menu_visible
    end,
    snippet_active = function(filter)
      return type(filter) == "table" and filter.direction == snippet_direction
    end,
    snippet_forward = function()
      snippet_forward_calls = snippet_forward_calls + 1
      return true
    end,
    snippet_backward = function()
      snippet_backward_calls = snippet_backward_calls + 1
      return true
    end,
    select_and_accept = function()
      select_and_accept_calls = select_and_accept_calls + 1
      return true
    end,
    accept = function()
      accept_calls = accept_calls + 1
      return true
    end,
    cancel = function(opts)
      cancel_calls = cancel_calls + 1
      if opts and opts.callback then
        opts.callback()
      end
      return true
    end,
  }
end

local console = require("ark.console")

menu_visible = true
assert(console.accept_completion_or_insert_tab() == true, "visible menu <Tab> should be handled")
assert(select_and_accept_calls == 1, "visible menu <Tab> should select and accept completion")
assert(fed_keys == nil, "visible menu <Tab> should not feed a literal tab")

menu_visible = false
snippet_direction = nil
console.accept_completion_or_insert_tab()
assert(
  fed_keys == vim.api.nvim_replace_termcodes("<Tab>", true, false, true),
  "hidden menu <Tab> should feed a literal tab"
)
assert(fed_mode == "n", "literal tab feed should avoid remapping")
assert(fed_escape_ks == false, "literal tab feed should preserve keycodes")

fed_keys = nil
menu_visible = true
console.bypass_completion_or_shift_tab()
assert(cancel_calls == 1, "visible menu <S-Tab> should cancel completion")
assert(
  fed_keys == vim.api.nvim_replace_termcodes("<Tab>", true, false, true),
  "visible menu <S-Tab> should feed a literal tab after cancel"
)

fed_keys = nil
menu_visible = false
snippet_direction = -1
console.bypass_completion_or_shift_tab()
assert(snippet_backward_calls == 1, "hidden menu <S-Tab> should preserve snippet backward")
assert(fed_keys == nil, "snippet backward should not feed a key")

menu_visible = true
select_and_accept_calls = 0
accept_calls = 0
local ok = console.submit_or_accept_completion(0)
assert(ok == true, "visible menu <CR> should accept completion")
assert(select_and_accept_calls == 1, "visible menu <CR> should select and accept completion")
assert(accept_calls == 0, "visible menu <CR> should not fall through to plain accept after select_and_accept")

menu_visible = false
select_and_accept_calls = 0
accept_calls = 0
ok = console.submit_or_accept_completion(0)
assert(ok == nil, "hidden menu <CR> should still call submit without a console buffer")
assert(select_and_accept_calls == 0, "hidden menu <CR> should not accept completion")
assert(accept_calls == 0, "hidden menu <CR> should not call plain accept")

menu_visible = true
accept_calls = 0
undo_preview_calls = 0
trigger_hide_calls = 0
menu_close_calls = 0
local insert_newline_calls = 0
local insert_newline_bufnr
local insert_newline_original = console.insert_newline
console.insert_newline = function(bufnr)
  insert_newline_calls = insert_newline_calls + 1
  insert_newline_bufnr = bufnr
  return true
end
assert(console.insert_newline_ignoring_completion(42) == true, "<M-CR> should insert a console newline")
assert(accept_calls == 0, "<M-CR> newline path should not accept completion")
assert(undo_preview_calls == 1, "<M-CR> should synchronously undo Blink completion preview")
assert(trigger_hide_calls == 1, "<M-CR> should hide Blink completion trigger state")
assert(menu_close_calls == 1, "<M-CR> should close Blink completion menu")
assert(insert_newline_calls == 1, "<M-CR> should call the console newline implementation")
assert(insert_newline_bufnr == 42, "<M-CR> should preserve the console buffer")
console.insert_newline = insert_newline_original

vim.api.nvim_feedkeys = feedkeys_original

print("nvim console completion key policy ok")
vim.cmd("qa!")
