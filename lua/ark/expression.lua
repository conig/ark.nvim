local M = {}

local function is_ident_start(char)
  return type(char) == "string" and char:match("[%a_.]") ~= nil
end

local function is_ident_char(char)
  return type(char) == "string" and char:match("[%w_.]") ~= nil
end

local function skip_ws(text, index)
  local cursor = index
  while cursor <= #text and text:sub(cursor, cursor):match("%s") do
    cursor = cursor + 1
  end
  return cursor
end

local function parse_identifier(text, index)
  if not is_ident_start(text:sub(index, index)) then
    return nil, index
  end

  local cursor = index + 1
  while cursor <= #text and is_ident_char(text:sub(cursor, cursor)) do
    cursor = cursor + 1
  end

  return text:sub(index, cursor - 1), cursor
end

local function matching_call_close(text, open_index)
  local depth = 0
  local quote = nil
  local comment = false
  local cursor = open_index

  while cursor <= #text do
    local char = text:sub(cursor, cursor)

    if quote then
      if quote ~= "`" and char == "\\" then
        cursor = cursor + 2
      elseif char == quote then
        quote = nil
        cursor = cursor + 1
      else
        cursor = cursor + 1
      end
    elseif comment then
      cursor = cursor + 1
    elseif char == "#" then
      comment = true
      cursor = cursor + 1
    elseif char == "'" or char == '"' or char == "`" then
      quote = char
      cursor = cursor + 1
    elseif char == "(" then
      depth = depth + 1
      cursor = cursor + 1
    elseif char == ")" then
      depth = depth - 1
      if depth == 0 then
        return cursor
      end
      cursor = cursor + 1
    else
      cursor = cursor + 1
    end
  end

  return nil
end

local function call_expr_on_line(line, cursor_col)
  if type(line) ~= "string" or line == "" then
    return nil
  end

  local cursor_byte = math.max(1, (tonumber(cursor_col) or 0) + 1)
  local index = 1
  local best = nil

  while index <= #line do
    local call_start = index
    local first, after_first = parse_identifier(line, index)
    if not first then
      index = index + 1
    else
      local after_name = after_first
      local operator = line:sub(after_first, after_first + 2)
      if operator == ":::" then
        local second, after_second = parse_identifier(line, after_first + 3)
        if second then
          after_name = after_second
        end
      elseif line:sub(after_first, after_first + 1) == "::" then
        local second, after_second = parse_identifier(line, after_first + 2)
        if second then
          after_name = after_second
        end
      end

      local open_index = skip_ws(line, after_name)
      if line:sub(open_index, open_index) == "(" then
        local close_index = matching_call_close(line, open_index)
        if close_index then
          if call_start <= cursor_byte and cursor_byte <= close_index + 1 then
            local candidate = {
              start = call_start,
              close = close_index,
              text = vim.trim(line:sub(call_start, close_index)),
            }
            if not best or (candidate.close - candidate.start) < (best.close - best.start) then
              best = candidate
            end
          end
          index = close_index + 1
        else
          index = after_name
        end
      else
        index = after_name
      end
    end
  end

  return best and best.text or nil
end

function M.selection_text()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
    return nil
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local start_line = vim.fn.line("v")
  local end_line = vim.fn.line(".")
  local start_col = vim.fn.col("v")
  local end_col = vim.fn.col(".")

  if start_line > end_line or (start_line == end_line and start_col > end_col) then
    start_line, end_line = end_line, start_line
    start_col, end_col = end_col, start_col
  end

  local lines
  if mode == "V" then
    lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  else
    lines = vim.api.nvim_buf_get_text(bufnr, start_line - 1, start_col - 1, end_line - 1, end_col, {})
  end

  local text = table.concat(lines, "\n"):gsub("^%s*(.-)%s*$", "%1")
  return text ~= "" and text or nil
end

function M.call_expr()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]
  local col = cursor[2]
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
  return call_expr_on_line(line, col)
end

function M.treesitter_expr()
  if type(vim.treesitter) ~= "table" or type(vim.treesitter.get_node) ~= "function" then
    return nil
  end

  local ok, node = pcall(vim.treesitter.get_node, { ignore_injections = false })
  if not ok then
    return nil
  end
  if not node then
    return nil
  end

  local function parent_type_is(type_name)
    local parent = node and node:parent()
    return parent and parent:type() == type_name
  end

  while parent_type_is("extract_operator") do
    node = node:parent()
  end

  if parent_type_is("namespace_operator") then
    node = node:parent()
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local start_row, start_col, end_row, end_col = node:range()
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
  if #lines == 0 then
    return nil
  end

  if #lines == 1 then
    return string.sub(lines[1], start_col + 1, end_col)
  end

  lines[1] = string.sub(lines[1], start_col + 1)
  lines[#lines] = string.sub(lines[#lines], 1, end_col)
  return table.concat(lines, "\n")
end

function M.current()
  local selected = M.selection_text()
  if selected then
    return selected
  end

  local expr = M.call_expr()
  if type(expr) == "string" and expr ~= "" then
    return expr
  end

  expr = M.treesitter_expr()
  if type(expr) == "string" and expr ~= "" then
    return expr
  end

  expr = vim.fn.expand("<cword>")
  return expr ~= "" and expr or nil
end

return M
