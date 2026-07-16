local M = {}

M.column_min_width = 8
M.column_override_min_width = 4
M.column_override_max_width = 200
M.column_width_step = 8

local column_max_width = M.column_override_max_width
local column_separator_width = 3
local horizontal_render_min_width = 420
local horizontal_render_width_multiplier = 3
local state_caches = setmetatable({}, { __mode = "k" })

function M.display_width(text)
  return vim.fn.strdisplaywidth(tostring(text or ""))
end

function M.clamp_width(width, min_width, max_width)
  width = tonumber(width) or min_width
  return math.max(min_width, math.min(max_width, width))
end

function M.sidebar_split_width(total_width)
  total_width = tonumber(total_width) or vim.o.columns
  total_width = math.max(1, total_width)

  local max_sidebar_width = math.max(1, math.floor((total_width - 1) / 4))
  local target = math.floor(total_width * 0.2)
  target = math.max(12, math.min(34, target))

  return math.max(1, math.min(target, max_sidebar_width))
end

function M.clip_text(text, width)
  text = tostring(text or "")
  if width <= 0 then
    return ""
  end
  if M.display_width(text) <= width then
    return text
  end
  if width == 1 then
    return text:sub(1, 1)
  end
  return text:sub(1, width - 1) .. ">"
end

function M.pad_text(text, width)
  text = M.clip_text(text, width)
  local padding = width - M.display_width(text)
  if padding <= 0 then
    return text
  end
  return text .. string.rep(" ", padding)
end

function M.blank_text(width)
  return string.rep(" ", math.max(0, tonumber(width) or 0))
end

function M.column_class_label(item)
  if type(item) ~= "table" then
    return "<unknown>"
  end

  local class = item.class or item.type or "unknown"
  if type(class) == "table" then
    class = table.concat(class, "/")
  end
  class = vim.trim(tostring(class or ""))
  if class == "" then
    class = "unknown"
  end

  return "<" .. class .. ">"
end

function M.split_display_width(text, width)
  text = tostring(text or "")
  width = tonumber(width) or 0
  if width <= 0 then
    return { "" }
  end
  if M.display_width(text) <= width then
    return { text }
  end

  local lines = {}
  local current = ""
  local count = vim.fn.strchars(text)
  for index = 0, count - 1 do
    local char = vim.fn.strcharpart(text, index, 1)
    if current ~= "" and M.display_width(current .. char) > width then
      lines[#lines + 1] = current
      current = char
    else
      current = current .. char
    end
  end
  lines[#lines + 1] = current
  return lines
end

local function state_cache(state)
  local cache = state_caches[state]
  if type(cache) ~= "table" or cache.schema ~= state.schema then
    local by_index = {}
    local positions = {}
    for position, item in ipairs(state.schema or {}) do
      local column_index = tonumber(item.index)
      if column_index and by_index[column_index] == nil then
        by_index[column_index] = item
        positions[column_index] = position
      end
    end
    cache = {
      schema = state.schema,
      rows = state.rows,
      by_index = by_index,
      positions = positions,
      widths = {},
    }
    state_caches[state] = cache
  elseif cache.rows ~= state.rows then
    cache.rows = state.rows
    cache.widths = {}
  end
  return cache
end

function M.schema_by_index(state, column_index)
  local target = tonumber(column_index)
  if not state or not target then
    return nil
  end
  return state_cache(state).by_index[target]
end

function M.schema_position_for_column(state, column_index)
  local target = tonumber(column_index)
  if not state or not target then
    return nil
  end
  return state_cache(state).positions[target]
end

function M.row_value(row, column_index)
  if type(row) ~= "table" then
    return nil
  end

  local numeric = tonumber(column_index)
  return row[numeric] or row[tostring(numeric)]
end

local function automatic_column_width(state, item)
  local column_index = tonumber(item and item.index)
  if not column_index then
    return M.column_min_width
  end

  local widths = state_cache(state).widths
  if widths[column_index] then
    return widths[column_index]
  end

  local width = M.clamp_width(
    math.max(M.display_width(item.name or ""), M.display_width(M.column_class_label(item))),
    M.column_min_width,
    column_max_width
  )
  for _, row in ipairs(state.rows or {}) do
    width = math.max(
      width,
      M.clamp_width(M.display_width(M.row_value(row, column_index)), M.column_min_width, column_max_width)
    )
  end

  width = M.clamp_width(width, M.column_min_width, column_max_width)
  widths[column_index] = width
  return width
end

local function column_width(state, item)
  local column_index = tonumber(item and item.index)
  if not column_index then
    return M.column_min_width
  end

  local override = tonumber((state.column_width_overrides or {})[column_index])
  if override then
    return M.clamp_width(override, M.column_override_min_width, M.column_override_max_width)
  end

  return automatic_column_width(state, item)
end

function M.grid_width_budget(viewport_width)
  local width = math.max(1, tonumber(viewport_width) or 80)
  return math.max(horizontal_render_min_width, width * horizontal_render_width_multiplier)
end

function M.visible_grid_columns(state, row_width, viewport_width)
  local schema = state.schema or {}
  if #schema == 0 then
    return {}, {}, {}
  end

  local selected_position = M.schema_position_for_column(state, state.selected_column) or 1
  selected_position = math.max(1, math.min(#schema, selected_position))

  local widths = {}
  local positions = {}
  local total_width = row_width
  local budget = M.grid_width_budget(viewport_width)

  local function add_position(position, at_start, force)
    local item = schema[position]
    if not item then
      return false
    end

    local column_index = tonumber(item.index) or 0
    local width = column_width(state, item)
    local next_width = total_width + column_separator_width + width
    if not force and #positions > 0 and next_width > budget then
      return false
    end

    widths[column_index] = width
    if at_start then
      table.insert(positions, 1, position)
    else
      positions[#positions + 1] = position
    end
    total_width = next_width
    return true
  end

  add_position(selected_position, false, true)

  local left = selected_position - 1
  local right = selected_position + 1
  local left_open = left >= 1
  local right_open = right <= #schema
  local prefer_left = selected_position > 1

  while left_open or right_open do
    local progressed = false

    if prefer_left then
      if left_open then
        if add_position(left, true, false) then
          left = left - 1
          left_open = left >= 1
          progressed = true
        else
          left_open = false
        end
      end
      if right_open then
        if add_position(right, false, false) then
          right = right + 1
          right_open = right <= #schema
          progressed = true
        else
          right_open = false
        end
      end
    else
      if right_open then
        if add_position(right, false, false) then
          right = right + 1
          right_open = right <= #schema
          progressed = true
        else
          right_open = false
        end
      end
      if left_open then
        if add_position(left, true, false) then
          left = left - 1
          left_open = left >= 1
          progressed = true
        else
          left_open = false
        end
      end
    end

    prefer_left = not prefer_left
    if not progressed then
      break
    end
  end

  local visible_schema = {}
  for _, position in ipairs(positions) do
    visible_schema[#visible_schema + 1] = schema[position]
  end

  return visible_schema, widths, positions
end

function M.page_columns(state, row_width, viewport_width)
  local visible_schema = M.visible_grid_columns(state, row_width, viewport_width)
  local columns = {}
  local seen = {}
  local function add(column_index)
    column_index = tonumber(column_index)
    if not column_index or seen[column_index] then
      return
    end
    seen[column_index] = true
    columns[#columns + 1] = column_index
  end
  for _, item in ipairs(visible_schema or {}) do
    add(item.index)
  end
  add(state.pinned_column)
  return columns
end

function M.page_includes_column(state, column_index)
  local columns = state and state.page_columns
  if type(columns) ~= "table" or #columns == 0 then
    return true
  end

  local target = tonumber(column_index)
  if not target then
    return false
  end
  for _, loaded_column in ipairs(columns) do
    if tonumber(loaded_column) == target then
      return true
    end
  end
  return false
end

function M.pinned_column_width(state, column_index, row_width, editor_width)
  local override = tonumber((state.column_width_overrides or {})[column_index])
  if override then
    return M.clamp_width(override, M.column_override_min_width, M.column_override_max_width)
  end

  editor_width = tonumber(editor_width) or 80
  local pinned_width = math.max(12, math.floor(editor_width * 0.5))
  local available = math.max(M.column_min_width, pinned_width - row_width - column_separator_width - 1)
  local width = automatic_column_width(state, M.schema_by_index(state, column_index))
  return math.max(M.column_min_width, math.min(width, available))
end

return M
