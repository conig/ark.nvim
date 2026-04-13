vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local buffer_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/ark_view_live.R")
local stop_watchdog = ark_test.start_watchdog(120000, "ark_view_live")

local ok, err = pcall(function()
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
