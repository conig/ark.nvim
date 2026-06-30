vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local buffer_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/ark_view_live.R")
local stop_watchdog = ark_test.start_watchdog(120000, "ark_view_live")

local function rebuild_bridge_runtime()
  local bridge = require("ark.bridge")
  local config = require("ark.config").defaults().tmux
  local completed = nil
  local ok, build_err = bridge.build_session_runtime(config, {
    on_complete = function(result)
      completed = result
    end,
  })
  if not ok then
    error("failed to rebuild pane-side arkbridge runtime: " .. vim.inspect(build_err), 0)
  end

  local ready = vim.wait(30000, function()
    return type(completed) == "table"
  end, 50, false)
  if not ready or completed.ok ~= true then
    error("timed out rebuilding pane-side arkbridge runtime: " .. vim.inspect(completed), 0)
  end
end

local ok, err = pcall(function()
  rebuild_bridge_runtime()

  local _, client = ark_test.setup_managed_buffer(buffer_path, { "mtcars" })

  local opened = ark_test.request(client, "ark/internal/viewOpen", {
    expr = "mtcars",
  }, 10000)

  if type(opened.session_id) ~= "string" or opened.session_id == "" then
    error("expected viewOpen to return a session_id, got " .. vim.inspect(opened), 0)
  end

  if tonumber(opened.total_rows or 0) < 30 then
    error("expected mtcars rows from viewOpen, got " .. vim.inspect(opened.total_rows), 0)
  end

  local schema = opened.schema or {}
  if type(schema[1]) ~= "table" or schema[1].name ~= "mpg" then
    error("expected first schema column to be mpg, got " .. vim.inspect(schema[1]), 0)
  end

  local page = ark_test.request(client, "ark/internal/viewPage", {
    sessionId = opened.session_id,
    offset = 0,
    limit = 5,
  }, 10000)

  if type(page.rows) ~= "table" or type(page.rows[1]) ~= "table" then
    error("expected page rows from viewPage, got " .. vim.inspect(page), 0)
  end

  local first_value = tostring((page.rows[1] or {})[1] or "")
  if not first_value:match("^21") then
    error("expected first mpg cell from mtcars page, got " .. vim.inspect(page.rows[1]), 0)
  end

  -- Regression: ArkView is a user-initiated table operation and must not use
  -- the same tight bridge timeout as latency-sensitive completion requests.
  -- Real wide targets such as DAvalidate's final_data can legitimately take
  -- more than one second to evaluate and serialize their schema.
  local slow_view = ark_test.request(client, "ark/internal/viewOpen", {
    expr = [[local({ Sys.sleep(1.2); as.data.frame(setNames(as.list(seq_len(12)), sprintf("col_%02d", seq_len(12)))) })]],
  }, 10000)

  if tonumber(slow_view.total_columns or 0) ~= 12 then
    error("expected slow ArkView table to open with 12 columns, got " .. vim.inspect(slow_view), 0)
  end

  -- Regression: visually empty strings must be distinguishable in ArkView's
  -- page payload before the Lua grid pads them into fixed-width cells.
  local string_view = ark_test.request(client, "ark/internal/viewOpen", {
    expr = [[data.frame(x = c("", " ", "   ", " a ", "a b", "a  b"), y = seq_len(6), stringsAsFactors = FALSE)]],
  }, 10000)

  local string_page = ark_test.request(client, "ark/internal/viewPage", {
    sessionId = string_view.session_id,
    offset = 0,
    limit = 6,
  }, 10000)

  local string_values = {}
  for index, row in ipairs(string_page.rows or {}) do
    string_values[index] = (row or {})[1]
  end

  local expected_string_values = {
    [[""]],
    [[\x20]],
    [[\x20\x20\x20]],
    [[\x20a\x20]],
    "a b",
    [[a\x20\x20b]],
  }
  if not vim.deep_equal(string_values, expected_string_values) then
    error(
      "expected ArkView string display values to reveal empty and whitespace-only cells, got "
        .. vim.inspect(string_values),
      0
    )
  end

  ark_test.request(client, "ark/internal/viewClose", {
    sessionId = string_view.session_id,
  }, 10000)

  local one_column_string_view = ark_test.request(client, "ark/internal/viewOpen", {
    expr = [[data.frame(x = c("", " "), stringsAsFactors = FALSE)]],
  }, 10000)

  local one_column_string_page = ark_test.request(client, "ark/internal/viewPage", {
    sessionId = one_column_string_view.session_id,
    offset = 0,
    limit = 2,
  }, 10000)

  if
    type((one_column_string_page.rows or {})[1]) ~= "table"
    or (one_column_string_page.rows[1] or {})[1] ~= [[""]]
    or (one_column_string_page.rows[2] or {})[1] ~= [[\x20]]
  then
    error("expected one-column ArkView rows to remain row arrays, got " .. vim.inspect(one_column_string_page), 0)
  end

  ark_test.request(client, "ark/internal/viewClose", {
    sessionId = one_column_string_view.session_id,
  }, 10000)

  local filter_view = ark_test.request(client, "ark/internal/viewOpen", {
    expr = [[data.frame(score = c(1, 4, 5, 10), group = c("alpha", "beta", "alphabet", "beta"), stringsAsFactors = FALSE)]],
  }, 10000)

  local group_values = ark_test.request(client, "ark/internal/viewValues", {
    sessionId = filter_view.session_id,
    columnIndex = 2,
  }, 10000)

  local beta_value = nil
  for _, item in ipairs(group_values.values or {}) do
    if item.label == "beta" then
      beta_value = item
      break
    end
  end
  if beta_value == nil or tonumber(beta_value.count or 0) ~= 2 or type(beta_value.value_key) ~= "string" then
    error("expected value picker payload to include beta count and key, got " .. vim.inspect(group_values), 0)
  end

  local exact_group = ark_test.request(client, "ark/internal/viewFilter", {
    sessionId = filter_view.session_id,
    columnIndex = 2,
    query = beta_value.label,
    mode = "exact",
    valueKey = beta_value.value_key,
    label = beta_value.label,
  }, 10000)

  if tonumber(exact_group.total_rows or 0) ~= 2 or (exact_group.filters or {})[1].mode ~= "exact" then
    error("expected exact value filter to keep two beta rows, got " .. vim.inspect(exact_group), 0)
  end

  local values_ignoring_own_filter = ark_test.request(client, "ark/internal/viewValues", {
    sessionId = filter_view.session_id,
    columnIndex = 2,
  }, 10000)
  if tonumber(values_ignoring_own_filter.total_values or 0) ~= 3 then
    error("expected value facets to ignore the current column filter, got " .. vim.inspect(values_ignoring_own_filter), 0)
  end

  ark_test.request(client, "ark/internal/viewFilter", {
    sessionId = filter_view.session_id,
    columnIndex = 2,
    query = "",
  }, 10000)

  local less_than = ark_test.request(client, "ark/internal/viewFilter", {
    sessionId = filter_view.session_id,
    columnIndex = 1,
    query = "< 5",
  }, 10000)

  if tonumber(less_than.total_rows or 0) ~= 2 or (less_than.filters or {})[1].mode ~= "lt" then
    error("expected numeric < filter to keep score < 5 rows, got " .. vim.inspect(less_than), 0)
  end

  local greater_than = ark_test.request(client, "ark/internal/viewFilter", {
    sessionId = filter_view.session_id,
    columnIndex = 1,
    query = ">5",
  }, 10000)

  if tonumber(greater_than.total_rows or 0) ~= 1 or (greater_than.filters or {})[1].mode ~= "gt" then
    error("expected numeric > filter to keep score > 5 rows, got " .. vim.inspect(greater_than), 0)
  end

  ark_test.request(client, "ark/internal/viewClose", {
    sessionId = filter_view.session_id,
  }, 10000)

  local mpg_profile = ark_test.request(client, "ark/internal/viewProfile", {
    sessionId = opened.session_id,
    columnIndex = 1,
  }, 10000)

  if type(mpg_profile.text) ~= "string"
    or not mpg_profile.text:find("Unique values:", 1, true)
    or not mpg_profile.text:find("Median:", 1, true)
    or not mpg_profile.text:find("Max:", 1, true)
    or not mpg_profile.text:find("Distribution:", 1, true)
    or not mpg_profile.text:find("#", 1, true)
  then
    error("expected numeric profile to include unique values and an ASCII distribution, got " .. vim.inspect(mpg_profile), 0)
  end

  local cyl_profile = ark_test.request(client, "ark/internal/viewProfile", {
    sessionId = opened.session_id,
    columnIndex = 2,
  }, 10000)

  if type(cyl_profile.text) ~= "string"
    or not cyl_profile.text:find("Unique values: 3", 1, true)
    or not cyl_profile.text:find("Top values:", 1, true)
    or not cyl_profile.text:find("8: 14", 1, true)
  then
    error("expected profile to include unique count and top value frequencies, got " .. vim.inspect(cyl_profile), 0)
  end

  local sorted = ark_test.request(client, "ark/internal/viewSort", {
    sessionId = opened.session_id,
    columnIndex = 1,
    direction = "desc",
  }, 10000)

  if sorted.sort == nil or sorted.sort.direction ~= "desc" then
    error("expected descending sort state, got " .. vim.inspect(sorted.sort), 0)
  end

  local sorted_page = ark_test.request(client, "ark/internal/viewPage", {
    sessionId = opened.session_id,
    offset = 0,
    limit = 1,
  }, 10000)

  local sorted_value = tostring(((sorted_page.rows or {})[1] or {})[1] or "")
  if not sorted_value:match("^33%.9") then
    error("expected sorted mpg cell 33.9, got " .. vim.inspect(sorted_page.rows), 0)
  end

  local filtered = ark_test.request(client, "ark/internal/viewFilter", {
    sessionId = opened.session_id,
    columnIndex = 1,
    query = "33.9",
  }, 10000)

  if tonumber(filtered.total_rows or 0) ~= 1 then
    error("expected one filtered row for mpg 33.9, got " .. vim.inspect(filtered.total_rows), 0)
  end

  local code = ark_test.request(client, "ark/internal/viewCode", {
    sessionId = opened.session_id,
  }, 10000)

  if type(code.code) ~= "string" or not code.code:find("grepl", 1, true) or not code.code:find("order", 1, true) then
    error("expected generated code with filter and sort, got " .. vim.inspect(code), 0)
  end

  local exported = ark_test.request(client, "ark/internal/viewExport", {
    sessionId = opened.session_id,
    format = "tsv",
  }, 10000)

  if type(exported.text) ~= "string" or not exported.text:find("mpg", 1, true) then
    error("expected exported text to include header row, got " .. vim.inspect(exported), 0)
  end

  local cell = ark_test.request(client, "ark/internal/viewCell", {
    sessionId = opened.session_id,
    rowIndex = 1,
    columnIndex = 1,
  }, 10000)

  if type(cell.text) ~= "string" or cell.text == "" then
    error("expected cell inspect text, got " .. vim.inspect(cell), 0)
  end

  local closed = ark_test.request(client, "ark/internal/viewClose", {
    sessionId = opened.session_id,
  }, 10000)

  if closed.closed ~= true then
    error("expected viewClose confirmation, got " .. vim.inspect(closed), 0)
  end
end)

stop_watchdog()

if not ok then
  error(err, 0)
end
