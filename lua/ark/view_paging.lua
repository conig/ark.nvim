local M = {}

local vertical_render_min_rows = 160
local vertical_render_height_multiplier = 4
local vertical_render_max_rows = 400

function M.virtual_row_limit(viewport_height)
  local height = math.max(1, tonumber(viewport_height) or 24)
  local limit = math.floor(height * vertical_render_height_multiplier)
  return math.max(vertical_render_min_rows, math.min(vertical_render_max_rows, limit))
end

function M.requested_page_limit(state)
  return math.max(0, tonumber(state and state.requested_page_limit or 0) or 0)
end

function M.should_virtualize_rows(state, viewport_height)
  return not (state and state.virtual_rows_allowed == false)
    and M.requested_page_limit(state) == 0
    and (tonumber(state and state.total_rows or 0) or 0) > M.virtual_row_limit(viewport_height)
end

function M.update_virtual_rows(state, viewport_height)
  if not state then
    return false
  end
  state.virtual_rows = M.should_virtualize_rows(state, viewport_height)
  return state.virtual_rows
end

function M.row_request_limit(state, viewport_height)
  if M.update_virtual_rows(state, viewport_height) then
    return M.virtual_row_limit(viewport_height)
  end
  return M.requested_page_limit(state)
end

function M.max_page_offset(state, limit)
  limit = tonumber(limit) or 0
  if limit < 1 then
    return 0
  end
  return math.max(0, (tonumber(state and state.total_rows or 0) or 0) - limit)
end

function M.normalize_page_offset(state, offset, limit)
  offset = math.max(0, tonumber(offset or (state and state.page_offset) or 0) or 0)
  limit = tonumber(limit) or 0
  if limit > 0 then
    offset = math.min(offset, M.max_page_offset(state, limit))
  end
  return offset
end

return M
