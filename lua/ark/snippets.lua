local M = {}

local SNIPPETS = {
  {
    id = "lib",
    label = "lib",
    description = "Load a package with `library()`",
    body = "library(${1:package})",
  },
  {
    id = "req",
    label = "req",
    description = "Load a package with `require()`",
    body = "require(${1:package})",
  },
  {
    id = "src",
    label = "src",
    description = "Source an R file",
    body = 'source("${1:file.R}")',
  },
  {
    id = "ret",
    label = "ret",
    description = "Return a value",
    body = "return(${1:value})",
  },
  {
    id = "if",
    label = "if",
    description = "Insert `if` statement",
    body = table.concat({
      "if (${1:condition}) {",
      "\t${0}",
      "}",
    }, "\n"),
  },
  {
    id = "else",
    label = "else",
    description = "Insert `else` statement",
    body = table.concat({
      "else {",
      "\t${0}",
      "}",
    }, "\n"),
  },
  {
    id = "repeat",
    label = "repeat",
    description = "Insert `repeat` loop",
    body = table.concat({
      "repeat {",
      "\t${0}",
      "}",
    }, "\n"),
  },
  {
    id = "while",
    label = "while",
    description = "Insert `while` loop",
    body = table.concat({
      "while (${1:condition}) {",
      "\t${0}",
      "}",
    }, "\n"),
  },
  {
    id = "fun",
    label = "fun",
    description = "Define a function",
    body = table.concat({
      "${1:name} <- function(${2:variables}) {",
      "\t${0}",
      "}",
    }, "\n"),
  },
  {
    id = "for",
    label = "for",
    description = "Insert `for` loop",
    body = table.concat({
      "for (${1:variable} in ${2:vector}) {",
      "\t${0}",
      "}",
    }, "\n"),
  },
  {
    id = "switch",
    label = "switch",
    description = "Dispatch with `switch()`",
    body = table.concat({
      "switch (${1:object},",
      "\t${2:case} = ${3:action}",
      ")",
    }, "\n"),
  },
  {
    id = "apply",
    label = "apply",
    description = "Apply a function over an array margin",
    body = "apply(${1:array}, ${2:margin}, ${3:fun})",
  },
  {
    id = "lapply",
    label = "lapply",
    description = "Apply a function over a list",
    body = "lapply(${1:list}, ${2:fun})",
  },
  {
    id = "sapply",
    label = "sapply",
    description = "Simplifying list apply",
    body = "sapply(${1:list}, ${2:fun})",
  },
  {
    id = "vapply",
    label = "vapply",
    description = "Type-stable list apply",
    body = "vapply(${1:list}, ${2:fun}, FUN.VALUE = ${3:type})",
  },
  {
    id = "mapply",
    label = "mapply",
    description = "Apply a function in parallel over arguments",
    body = "mapply(${1:fun}, ${2:...})",
  },
  {
    id = "tapply",
    label = "tapply",
    description = "Apply a function over indexed subsets",
    body = "tapply(${1:vector}, ${2:index}, ${3:fun})",
  },
  {
    id = "rapply",
    label = "rapply",
    description = "Recursively apply a function over a list",
    body = "rapply(${1:list}, ${2:fun})",
  },
}

local function render_body(body)
  local parts = {}
  local index = 1
  local length = 0
  local first_placeholder = nil
  local final_stop = nil

  local function append(text)
    if text == "" then
      return
    end

    parts[#parts + 1] = text
    length = length + #text
  end

  while index <= #body do
    if body:sub(index, index) == "$" then
      local next_char = body:sub(index + 1, index + 1)
      if next_char == "{" then
        local close_index = body:find("}", index + 2, true)
        if close_index then
          local placeholder = body:sub(index + 2, close_index - 1)
          local slot, text = placeholder:match("^(%d+):(.*)$")
          if not slot then
            slot = placeholder:match("^(%d+)$")
            text = ""
          end

          if slot then
            local slot_number = tonumber(slot)
            if slot_number and slot_number > 0 and first_placeholder == nil then
              first_placeholder = length
            end
            if slot_number == 0 and final_stop == nil then
              final_stop = length
            end

            append(text or "")
            index = close_index + 1
            goto continue
          end
        end
      elseif next_char:match("%d") then
        local last_digit = index + 1
        while body:sub(last_digit + 1, last_digit + 1):match("%d") do
          last_digit = last_digit + 1
        end

        local slot_number = tonumber(body:sub(index + 1, last_digit))
        if slot_number == 0 and final_stop == nil then
          final_stop = length
        elseif slot_number and slot_number > 0 and first_placeholder == nil then
          first_placeholder = length
        end

        index = last_digit + 1
        goto continue
      end
    end

    append(body:sub(index, index))
    index = index + 1

    ::continue::
  end

  local text = table.concat(parts)
  return {
    text = text,
    cursor_offset = first_placeholder or final_stop or #text,
  }
end

local function cursor_from_offset(text, offset)
  local prefix = text:sub(1, math.max(0, offset or 0))
  local parts = vim.split(prefix, "\n", { plain = true })
  return {
    row_delta = #parts - 1,
    col = vim.fn.strchars(parts[#parts] or ""),
  }
end

local function insert_plain_text(bufnr, body)
  local rendered = render_body(body)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]
  local lines = vim.split(rendered.text, "\n", { plain = true })
  local cursor_pos = cursor_from_offset(rendered.text, rendered.cursor_offset)

  vim.api.nvim_buf_set_text(bufnr, row, col, row, col, lines)

  local target_col = cursor_pos.row_delta == 0 and (col + cursor_pos.col) or cursor_pos.col
  vim.api.nvim_win_set_cursor(0, { cursor[1] + cursor_pos.row_delta, target_col })
  vim.cmd("startinsert")
end

local function ensure_insert_mode()
  local mode = vim.api.nvim_get_mode().mode
  if not mode:match("^[iR]") then
    vim.cmd("startinsert")
  end
end

local function settle_after_expand()
  local next_mode = vim.api.nvim_get_mode().mode
  if not next_mode:match("^[isS]") then
    vim.cmd("startinsert")
  end
end

local function expand_with_luasnip(body)
  local ok, luasnip = pcall(require, "luasnip")
  if not ok or type(luasnip) ~= "table" or type(luasnip.lsp_expand) ~= "function" then
    return false
  end

  ensure_insert_mode()

  local expanded = pcall(luasnip.lsp_expand, body)
  if expanded then
    settle_after_expand()
    return true
  end

  return false
end

local function expand_with_builtin(body)
  if type(vim.snippet) == "table" and type(vim.snippet.expand) == "function" then
    ensure_insert_mode()

    local ok = pcall(vim.snippet.expand, body)
    if ok then
      settle_after_expand()
      return true
    end
  end

  return false
end

local function expand_snippet(bufnr, body)
  if expand_with_luasnip(body) then
    return true
  end

  if expand_with_builtin(body) then
    return true
  end

  insert_plain_text(bufnr, body)
  return true
end

local function format_item(item)
  return {
    { item.label, "Title" },
    { "  " },
    { item.description, "Comment" },
  }
end

local function picker_layout()
  return {
    preset = "vertical",
    layout = {
      width = 0.7,
      min_width = 60,
      height = 0.6,
      min_height = 16,
      box = "vertical",
      border = true,
      title = "{title}",
      title_pos = "center",
      { win = "input", height = 1, border = "bottom" },
      { win = "list", height = 0.3, border = "none" },
      { win = "preview", title = "{preview}", height = 0.7, border = "top" },
    },
  }
end

local function picker_items()
  local items = {}

  for _, snippet in ipairs(SNIPPETS) do
    local preview = render_body(snippet.body)
    items[#items + 1] = {
      id = snippet.id,
      label = snippet.label,
      description = snippet.description,
      body = snippet.body,
      text = table.concat({ snippet.label, snippet.description, snippet.id }, " "),
      preview = {
        text = preview.text,
        ft = "r",
        loc = false,
      },
    }
  end

  return items
end

function M.open(opts)
  opts = opts or {}

  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local filetypes = opts.filetypes or {}
  local notify = opts.notify or vim.notify
  local filetype = vim.bo[bufnr].filetype

  if not vim.tbl_contains(filetypes, filetype) then
    local err = "ark.nvim snippets require an R-family buffer"
    notify(err, vim.log.levels.WARN)
    return nil, err
  end

  local ok, snacks = pcall(require, "snacks")
  if not ok or type(snacks) ~= "table" or type(snacks.picker) ~= "table" or type(snacks.picker.pick) ~= "function" then
    local err = "snacks.nvim picker is required for Ark snippets"
    notify(err, vim.log.levels.ERROR)
    return nil, err
  end

  snacks.picker.pick({
    title = "Ark Snippets",
    items = picker_items(),
    format = format_item,
    preview = "preview",
    layout = picker_layout(),
    confirm = function(picker, item)
      picker:close()
      if not item then
        return
      end

      expand_snippet(bufnr, item.body)
    end,
  })

  return true
end

return M
