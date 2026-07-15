local M = {}

function M.parse_percent(value)
  value = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if value == "" or value:sub(1, 1) == "-" then
    return nil
  end
  local percent = tonumber(value:match("(%d+)"))
  if not percent then
    return nil
  end
  return tostring(math.max(10, math.min(90, percent)))
end

function M.parse_positive_integer(value)
  local number = tonumber(value)
  return number and number > 0 and math.floor(number) or nil
end

function M.parse_panes(output)
  local panes = {}
  for line in ((output or "") .. "\n"):gmatch("(.-)\n") do
    if line ~= "" then
      local pane_id, left, top, width, height, window_width, window_height =
        line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
      left, top, width, height = tonumber(left), tonumber(top), tonumber(width), tonumber(height)
      window_width, window_height = tonumber(window_width), tonumber(window_height)
      if pane_id and left and top and width and height and window_width and window_height then
        panes[#panes + 1] = {
          pane_id = pane_id,
          left = left,
          top = top,
          width = width,
          height = height,
          window_width = window_width,
          window_height = window_height,
        }
      end
    end
  end
  return panes
end

function M.find_pane(panes, pane_id)
  for _, pane in ipairs(panes or {}) do
    if pane.pane_id == pane_id then
      return pane
    end
  end
end

function M.share_column(lhs, rhs)
  return lhs and rhs and lhs.left == rhs.left and lhs.width == rhs.width
end

function M.share_row(lhs, rhs)
  return lhs and rhs and lhs.top == rhs.top and lhs.height == rhs.height
end

local function spans_window_height(pane)
  return pane and pane.top == 0 and pane.height >= (pane.window_height - 1)
end

function M.normalize(value)
  if value == nil then
    return "auto"
  end
  if type(value) ~= "string" or value == "" then
    return nil
  end
  value = value:lower()
  if value == "auto" then
    return value
  end
  if value == "side_by_side" or value == "horizontal" or value == "landscape" then
    return "side_by_side"
  end
  if value == "stacked" or value == "vertical" or value == "portrait" then
    return "stacked"
  end
end

function M.layout(name)
  if name == "stacked" then
    return { name = "stacked", split_flag = "-v" }
  end
  return { name = "side_by_side", split_flag = "-h" }
end

function M.resolve_from_size(config, width, height)
  local name = M.normalize(config.pane_layout)
  if not name then
    return nil, "invalid ark.nvim tmux.pane_layout: " .. tostring(config.pane_layout)
  end
  if name ~= "auto" then
    return M.layout(name), nil
  end
  width, height = tonumber(width), tonumber(height)
  if not width or width <= 0 then
    return nil, "failed to resolve tmux window width"
  end
  if not height or height <= 0 then
    return nil, "failed to resolve tmux window height"
  end
  local stacked_max_width = tonumber(config.stacked_max_width)
  if (stacked_max_width and stacked_max_width > 0 and width <= stacked_max_width) or height > width then
    return M.layout("stacked"), nil
  end
  return M.layout("side_by_side"), nil
end

function M.existing_side_target(panes, anchor_pane_id)
  local anchor = M.find_pane(panes, anchor_pane_id)
  if not anchor or #panes < 2 or not spans_window_height(anchor) then
    return nil
  end
  local leftmost = anchor.left
  local target = nil
  for _, pane in ipairs(panes) do
    if spans_window_height(pane) then
      leftmost = math.min(leftmost, pane.left)
      if pane.left > anchor.left and (not target or pane.left < target.left) then
        target = pane
      end
    end
  end
  if target then
    return target.pane_id
  end
  return anchor.left > leftmost and anchor.pane_id or nil
end

function M.visible_placement(panes, anchor_pane_id, config, percent)
  local anchor = M.find_pane(panes, anchor_pane_id)
  if not anchor then
    return nil, "failed to find tmux anchor pane: " .. tostring(anchor_pane_id)
  end
  local layout, err = M.resolve_from_size(config, anchor.window_width, anchor.window_height)
  if not layout then
    return nil, err
  end
  local placement = {
    layout = layout,
    target_pane_id = anchor_pane_id,
    before = false,
    percent = type(percent) == "function" and percent(layout.name) or percent,
  }
  if layout.name == "side_by_side" then
    local side_target = M.existing_side_target(panes, anchor_pane_id)
    if side_target then
      placement.layout = M.layout("stacked")
      placement.target_pane_id = side_target
      placement.before = true
      placement.percent = "50"
    end
  end
  return placement, nil
end

return M
