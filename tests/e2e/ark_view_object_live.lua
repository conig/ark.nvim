vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local buffer_path = vim.fs.normalize(ark_test.run_tmpdir() .. "/ark_view_object_live.R")
local stop_watchdog = ark_test.start_watchdog(120000, "ark_view_object_live")

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

local function schema_names(payload)
  return vim.tbl_map(function(item)
    return item.name
  end, payload.schema or {})
end

local ok, err = pcall(function()
  rebuild_bridge_runtime()

  local _, client = ark_test.setup_managed_buffer(buffer_path, { "mtcars" })

  local vector_view = ark_test.request(client, "ark/internal/viewOpen", {
    expr = "c(alpha = 1, beta = 2)",
  }, 10000)
  if vector_view.kind ~= "table" or not vim.deep_equal(schema_names(vector_view), { "name", "value" }) then
    error("expected named vector to open as name/value table, got " .. vim.inspect(vector_view), 0)
  end

  local vector_page = ark_test.request(client, "ark/internal/viewPage", {
    sessionId = vector_view.session_id,
    offset = 0,
    limit = 0,
  }, 10000)
  if (vector_page.rows[1] or {})[1] ~= "alpha" or (vector_page.rows[1] or {})[2] ~= "1" then
    error("expected named vector row payload, got " .. vim.inspect(vector_page), 0)
  end

  local table_view = ark_test.request(client, "ark/internal/viewOpen", {
    expr = "table(c('a', 'b', 'a'))",
  }, 10000)
  if table_view.kind ~= "table" or not vim.deep_equal(schema_names(table_view), { "Var1", "Freq" }) then
    error("expected table() object to use as.data.frame.table shape, got " .. vim.inspect(table_view), 0)
  end

  local tree = ark_test.request(client, "ark/internal/viewOpen", {
    expr = "list(alpha = 1, nested = list(df = data.frame(id = 1:2, value = c('a', 'b'))))",
  }, 10000)
  if tree.kind ~= "tree" or type(tree.session_id) ~= "string" or tree.session_id == "" then
    error("expected list to open as object tree, got " .. vim.inspect(tree), 0)
  end

  local children = ark_test.request(client, "ark/internal/objectChildren", {
    sessionId = tree.session_id,
    nodeId = "",
    offset = 0,
    limit = 0,
  }, 10000)
  local child_names = vim.tbl_map(function(item)
    return item.name
  end, children.children or {})
  if not vim.deep_equal(child_names, { "alpha", "nested" }) then
    error("expected root list children, got " .. vim.inspect(children), 0)
  end

  local nested_children = ark_test.request(client, "ark/internal/objectChildren", {
    sessionId = tree.session_id,
    nodeId = "2",
    offset = 0,
    limit = 0,
  }, 10000)
  local df_node = (nested_children.children or {})[1] or {}
  if df_node.name ~= "df" or df_node.viewable_table ~= true then
    error("expected nested df node to be table-viewable, got " .. vim.inspect(nested_children), 0)
  end

  local detail = ark_test.request(client, "ark/internal/objectDetail", {
    sessionId = tree.session_id,
    nodeId = "2/1",
  }, 10000)
  if type(detail.text) ~= "string" or not detail.text:find("# data.frame: 2 x 2", 1, true) then
    error("expected nested df detail preview, got " .. vim.inspect(detail), 0)
  end

  local table_child = ark_test.request(client, "ark/internal/objectTable", {
    sessionId = tree.session_id,
    nodeId = "2/1",
  }, 10000)
  if table_child.kind ~= "table" or not vim.deep_equal(schema_names(table_child), { "id", "value" }) then
    error("expected nested df to open as regular table view, got " .. vim.inspect(table_child), 0)
  end

  local search = ark_test.request(client, "ark/internal/objectSearch", {
    sessionId = tree.session_id,
    query = "df",
    maxNodes = 1000,
    maxResults = 100,
  }, 10000)
  if #(search.matches or {}) ~= 1 or search.matches[1].node_id ~= "2/1" then
    error("expected object search to find nested df, got " .. vim.inspect(search), 0)
  end
end)

stop_watchdog()
if not ok then
  error(err, 0)
end
