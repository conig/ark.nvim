local ark_test = require("ark_test")

local function diagnostic_messages()
  local messages = {}
  for _, diagnostic in ipairs(vim.diagnostic.get(0)) do
    messages[#messages + 1] = diagnostic.message
  end
  table.sort(messages)
  return messages
end

local function diagnostic_messages_for_client(client)
  if not client then
    return {}
  end

  local namespace = vim.lsp.diagnostic.get_namespace(client.id)
  local messages = {}
  for _, diagnostic in ipairs(vim.diagnostic.get(0, { namespace = namespace })) do
    messages[#messages + 1] = diagnostic.message
  end
  table.sort(messages)
  return messages
end

local function contains(messages, needle)
  for _, message in ipairs(messages) do
    if message == needle then
      return true
    end
  end
  return false
end

local function completion_labels(result)
  local items = ark_test.completion_items(result)
  return ark_test.item_labels(items)
end

local function bridge_request(status, request)
  local tcp = assert((vim.uv or vim.loop).new_tcp())
  local done = false
  local chunks = {}
  local err_msg = nil

  local function close_client()
    pcall(tcp.read_stop, tcp)
    pcall(tcp.shutdown, tcp, function() end)
    pcall(tcp.close, tcp)
  end

  tcp:connect(status.session.tmux_socket and "127.0.0.1" or "127.0.0.1", tonumber(status.startup_status.port), function(connect_err)
    if connect_err then
      err_msg = tostring(connect_err)
      done = true
      close_client()
      return
    end

    tcp:read_start(function(read_err, chunk)
      if read_err then
        err_msg = tostring(read_err)
        done = true
        close_client()
        return
      end

      if chunk then
        chunks[#chunks + 1] = chunk
        return
      end

      done = true
      close_client()
    end)

    tcp:write(vim.json.encode(request) .. "\n", function(write_err)
      if write_err then
        err_msg = tostring(write_err)
        done = true
        close_client()
        return
      end

      tcp:shutdown(function(shutdown_err)
        if shutdown_err then
          err_msg = tostring(shutdown_err)
          done = true
          close_client()
        end
      end)
    end)
  end)

  local ok = vim.wait(3000, function()
    return done
  end, 10, false)

  if not ok or err_msg then
    return nil, err_msg or "bridge request timed out"
  end

  local decoded_ok, payload = pcall(vim.json.decode, table.concat(chunks, ""))
  if not decoded_ok then
    return nil, "failed to decode bridge response"
  end

  return payload, nil
end

local function bridge_search_path_members(status)
  local payload, err = bridge_request(status, {
    request_id = "ark-test-search-path",
    expr = 'local({ .envs <- lapply(search(), as.environment); .names <- unique(unlist(lapply(.envs, ls, all.names = TRUE), use.names = FALSE)); stats::setNames(vector("list", length(.names)), .names) })',
    options = {
      include_member_stats = false,
      max_members = 50000,
      request_profile = "completion_lean",
    },
    session = status.session,
    auth_token = status.startup_status.auth_token,
  })
  if not payload then
    return nil, err
  end

  if payload.error then
    return nil, payload.error.code .. ": " .. payload.error.message
  end

  local members = {}
  for _, member in ipairs(payload.members or {}) do
    members[#members + 1] = member.name_raw ~= "" and member.name_raw or member.name_display
  end
  return members, nil
end

-- This covers the user-visible startup shape where diagnostics can be computed
-- before a managed R session is live and must be corrected after the live LSP
-- takes over the same buffer.
require("ark").setup({
  auto_start_pane = false,
  auto_start_lsp = false,
  async_startup = false,
  configure_slime = true,
})

local test_file = "/tmp/ark_live_diagnostics_after_static_start.R"
vim.fn.writefile({
  "library(ggpl",
  "mtcars$mp",
}, test_file)

vim.cmd("edit " .. test_file)
vim.cmd("setfiletype r")

require("ark").start_lsp(0)

ark_test.wait_for("initial static lsp client", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  return client ~= nil and client.initialized == true and not client:is_stopped()
end)

local initial_client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]

ark_test.wait_for("initial diagnostics", 10000, function()
  return #vim.diagnostic.get(0) > 0
end)

local initial_messages = diagnostic_messages()
local initial_client_messages = diagnostic_messages_for_client(initial_client)

local pane_id, pane_err = require("ark").start_pane()
if not pane_id then
  error(pane_err or "failed to start managed pane", 0)
end

ark_test.wait_for("ark bridge ready", 20000, function()
  return require("ark").status().bridge_ready == true
end)

ark_test.wait_for("managed R repl ready", 20000, function()
  return require("ark").status().repl_ready == true
end)

ark_test.wait_for("original lsp client remains active", 15000, function()
  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  return client ~= nil
    and client.id == initial_client.id
    and client.initialized == true
    and not client:is_stopped()
end)

local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]

local library_result = ark_test.request(client, "textDocument/completion", {
  textDocument = vim.lsp.util.make_text_document_params(0),
  position = { line = 0, character = 12 },
}, 10000)

local mtcars_result = ark_test.request(client, "textDocument/completion", {
  textDocument = vim.lsp.util.make_text_document_params(0),
  position = { line = 1, character = 9 },
}, 10000)

local diagnostics_cleared = vim.wait(10000, function()
  local messages = diagnostic_messages()
  return not contains(messages, "No symbol named 'library' in scope.")
    and not contains(messages, "No symbol named 'mtcars' in scope.")
end, 100, false)

local final_messages = diagnostic_messages()
local final_client_messages = diagnostic_messages_for_client(client)
local bridge_members, bridge_err = bridge_search_path_members(require("ark").status())

if not diagnostics_cleared then
  error(vim.inspect({
    initial_client_id = initial_client and initial_client.id or nil,
    final_client_id = client.id,
    initial_diagnostics = initial_messages,
    initial_client_diagnostics = initial_client_messages,
    final_diagnostics = final_messages,
    final_client_diagnostics = final_client_messages,
    bridge_search_path_contains_mtcars = bridge_members and vim.tbl_contains(bridge_members, "mtcars") or nil,
    bridge_search_path_contains_library = bridge_members and vim.tbl_contains(bridge_members, "library") or nil,
    bridge_search_path_count = bridge_members and #bridge_members or nil,
    bridge_search_path_error = bridge_err,
    library_completion = completion_labels(library_result),
    mtcars_completion = completion_labels(mtcars_result),
    status = require("ark").status(),
    client_cmd_env = client.config and client.config.cmd_env or nil,
  }), 0)
end

if contains(final_messages, "No symbol named 'library' in scope.") then
  error(vim.inspect({
    initial_client_id = initial_client and initial_client.id or nil,
    final_client_id = client.id,
    initial_diagnostics = initial_messages,
    initial_client_diagnostics = initial_client_messages,
    final_diagnostics = final_messages,
    final_client_diagnostics = final_client_messages,
    library_completion = completion_labels(library_result),
    mtcars_completion = completion_labels(mtcars_result),
    bridge_search_path_contains_mtcars = bridge_members and vim.tbl_contains(bridge_members, "mtcars") or nil,
    bridge_search_path_contains_library = bridge_members and vim.tbl_contains(bridge_members, "library") or nil,
    bridge_search_path_count = bridge_members and #bridge_members or nil,
    bridge_search_path_error = bridge_err,
    status = require("ark").status(),
  }), 0)
end

if contains(final_messages, "No symbol named 'mtcars' in scope.") then
  error(vim.inspect({
    initial_client_id = initial_client and initial_client.id or nil,
    final_client_id = client.id,
    initial_diagnostics = initial_messages,
    initial_client_diagnostics = initial_client_messages,
    final_diagnostics = final_messages,
    final_client_diagnostics = final_client_messages,
    library_completion = completion_labels(library_result),
    mtcars_completion = completion_labels(mtcars_result),
    bridge_search_path_contains_mtcars = bridge_members and vim.tbl_contains(bridge_members, "mtcars") or nil,
    bridge_search_path_contains_library = bridge_members and vim.tbl_contains(bridge_members, "library") or nil,
    bridge_search_path_count = bridge_members and #bridge_members or nil,
    bridge_search_path_error = bridge_err,
    status = require("ark").status(),
  }), 0)
end

vim.print({
  initial_client_id = initial_client and initial_client.id or nil,
  final_client_id = client.id,
  initial_diagnostics = initial_messages,
  initial_client_diagnostics = initial_client_messages,
  final_diagnostics = final_messages,
  final_client_diagnostics = final_client_messages,
  library_completion = completion_labels(library_result),
  mtcars_completion = completion_labels(mtcars_result),
  bridge_search_path_contains_mtcars = bridge_members and vim.tbl_contains(bridge_members, "mtcars") or nil,
  bridge_search_path_contains_library = bridge_members and vim.tbl_contains(bridge_members, "library") or nil,
  bridge_search_path_count = bridge_members and #bridge_members or nil,
  bridge_search_path_error = bridge_err,
})
