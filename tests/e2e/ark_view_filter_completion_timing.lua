-- Canonical live benchmark: the reported world.cities/name failure, with real
-- Snacks input and live completion outstanding at the same time. R/bridge work
-- remains serialized; this measures responsive editing, not parallel R work.
local test = require("ark_test")
local perf = require("perf")
vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/snacks.nvim")
local snacks = require("snacks")
snacks.setup({ picker = { enabled = true } })
local ark = require("ark")
local lsp = require("ark.lsp")
local _, client = test.setup_managed_buffer(test.run_tmpdir() .. "/filter-completion.R", {
  "ark_perf_object$",
}, { view = { display = "tab" } })
local source_bufnr = vim.api.nvim_get_current_buf()
local params = {
  textDocument = vim.lsp.util.make_text_document_params(source_bufnr),
  position = { line = 0, character = #"ark_perf_object$" },
  context = { triggerKind = 1 },
}
assert(ark.send("ark_perf_object <- list(ark_perf_runtime_member = 42L)"))
test.wait_for("runtime-only completion fixture", 10000, function()
  local response = client:request_sync("textDocument/completion", params, 1000, source_bufnr)
  return response and test.find_item(test.completion_items(response.result), "ark_perf_runtime_member") ~= nil
end)

local measurements = {}
local expected_request
local original_values = lsp.view_values_async
local failure
local function now()
  return vim.uv.hrtime() / 1e6
end
local function check(condition, message)
  if not condition then
    failure = failure or message
  end
end

-- Instrument the genuine async boundary without replacing its transport,
-- payload, callback, cancellation, or picker implementation.
lsp.view_values_async = function(opts, bufnr, session_id, column_index, query, offset, limit, callback)
  local measurement = expected_request
  expected_request = nil
  assert(measurement, "unexpected extra value request (duplicate work)")
  check(column_index == 1 and limit == 1000, "benchmark did not filter bounded city names")
  local started = now()
  local sent, err, cancel = original_values(
    opts,
    bufnr,
    session_id,
    column_index,
    query,
    offset,
    limit,
    function(payload, value_err)
      measurement.values_ms = now() - started
      measurement.values_done = true
      check(not value_err and payload ~= nil, "value request failed: " .. tostring(value_err))
      if payload then
        check(#(payload.values or {}) <= 1000, "value response exceeded the 1000-item cap")
        check(payload.total_values > 40000, "fixture lost high cardinality")
        check(
          payload.diagnostics and payload.diagnostics.cache_hit == (measurement.phase == "warm"),
          "unexpected value-index cache state"
        )
        if query ~= "" then
          check(
            #payload.values == 1 and payload.values[1].label == query,
            "server search did not find the complete-index city"
          )
        end
      end
      callback(payload, value_err)
    end
  )
  assert(sent, err)
  check(not measurement.values_done, "value request blocked instead of returning asynchronously")
  local completion_started = now()
  local requested, request_err = client:request("textDocument/completion", params, function(completion_err, result)
    measurement.completion_ms = now() - completion_started
    measurement.completion_done = true
    check(not completion_err, "mixed completion failed: " .. vim.inspect(completion_err))
    check(
      test.find_item(test.completion_items(result), "ark_perf_runtime_member") ~= nil,
      "mixed completion lost the runtime-only member"
    )
  end, source_bufnr)
  assert(requested, request_err)
  return sent, err, cancel
end

local function measure(phase, trigger, ready)
  local measurement = { phase = phase, max_ui_lag_ms = 0, heartbeat_count = 0 }
  expected_request = measurement
  local last_tick = now()
  local measuring = true
  local timer = assert(vim.uv.new_timer())
  timer:start(
    10,
    10,
    vim.schedule_wrap(function()
      if not measuring then
        return
      end
      local tick = now()
      measurement.max_ui_lag_ms = math.max(measurement.max_ui_lag_ms, tick - last_tick - 10)
      measurement.heartbeat_count = measurement.heartbeat_count + 1
      last_tick = tick
    end)
  )
  local started = now()
  trigger()
  measurement.input_ms = now() - started
  local finished = vim.wait(10000, function()
    return failure or (measurement.values_done and measurement.completion_done and ready())
  end, 1)
  -- Include a stall ending immediately before response callbacks, even when
  -- the heartbeat's next scheduled callback has not yet had a chance to run.
  measurement.max_ui_lag_ms = math.max(measurement.max_ui_lag_ms, now() - last_tick - 10)
  measuring = false
  timer:stop()
  timer:close()
  assert(not failure, failure)
  assert(finished, "mixed filter/completion interaction timed out")
  -- A fast warm response may finish before the 10 ms heartbeat is due; faster
  -- machines must not fail merely for returning early. Cold indexing must
  -- service the UI, and every interaction still records end-to-end lateness.
  if phase == "cold" then
    assert(measurement.heartbeat_count > 0, "no UI heartbeat during cold indexing")
  end
  assert(expected_request == nil, "picker did not issue the expected value request")
  measurements[#measurements + 1] = measurement
end

local ok, err = pcall(function()
  local state = assert(ark.view("data.table::as.data.table(maps::world.cities)", source_bufnr))
  test.wait_for("initial viewport", 5000, function()
    return not state.page_loading
  end)
  assert(state.total_rows > 40000, "world.cities fixture is unexpectedly small")
  local picker
  measure("cold", function()
    vim.api.nvim_feedkeys("f", "xt", false)
  end, function()
    picker = snacks.picker.get()[1]
    return picker and #picker:items() > 0
  end)
  assert(#picker:items() <= 1000, "picker rendered an unbounded value list")
  for index = 1, 5 do
    local query = index % 2 == 1 and "Xianggangdao" or "Reykjavik"
    measure("warm", function()
      picker.input:set("", query)
      picker:find()
    end, function()
      return #picker:items() == 1 and picker:items()[1].item.label == query
    end)
  end
  -- Prove the measured selection still performs the requested exact filter.
  picker:action("confirm")
  test.wait_for("exact city filter applied", 5000, function()
    return state.total_rows == 1 and not state.page_loading and state.filters[1] and state.filters[1].mode == "exact"
  end)
  assert(vim.api.nvim_get_current_win() == state.grid_win, "filter changed the origin pane")
  ark.view_close()
end)
lsp.view_values_async = original_values
if not ok then
  error(err, 0)
end

-- File I/O for sample collection is outside every measured interaction. Keep
-- only timings/counts in output: never serialize source, queries, or data cells.
for _, measurement in ipairs(measurements) do
  local metadata = {
    test = "ark_view_filter_completion_timing.lua",
    condition = measurement.phase .. " value index; overlapping live member completion",
    fixture = "maps::world.cities: 43645 rows, 41074 distinct names",
  }
  perf.record("arkview.values." .. measurement.phase, measurement.values_ms, metadata)
  perf.record("arkview.filter.input", measurement.input_ms, metadata)
  perf.record("arkview.mixed.completion", measurement.completion_ms, metadata)
  perf.record("arkview.mixed.ui_lag", measurement.max_ui_lag_ms, metadata)
end
vim.print({ filter_completion_benchmark = "ok", interactions = #measurements })
