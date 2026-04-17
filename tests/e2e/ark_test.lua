local M = {}

local function sanitize_token(value)
  value = tostring(value or "")
  value = value:gsub("[^%w_%-]", "_")
  value = value:gsub("_+", "_")
  value = value:gsub("^_+", "")
  value = value:gsub("_+$", "")
  if value == "" then
    return "unknown"
  end
  return value
end

function M.fail(message)
  error(message, 0)
end

function M.run_id()
  local env_run_id = vim.env.ARK_TEST_RUN_ID
  if type(env_run_id) == "string" and env_run_id ~= "" then
    return sanitize_token(env_run_id)
  end
  return sanitize_token(vim.fn.getpid())
end

function M.run_tmpdir()
  local env_tmpdir = vim.env.ARK_TEST_TMPDIR
  if type(env_tmpdir) == "string" and env_tmpdir ~= "" then
    return vim.fs.normalize(env_tmpdir)
  end
  return vim.fs.normalize("/tmp/arktest-" .. M.run_id())
end

function M.tmux_session_name(base)
  local suffix = sanitize_token(base or "session")
  return "arktest_" .. M.run_id() .. "_" .. suffix
end

function M.register_tmux_session(name)
  local manifest = vim.env.ARK_TEST_TMUX_MANIFEST
  if type(manifest) == "string" and manifest ~= "" then
    vim.fn.writefile({ name }, manifest, "a")
  end
  return name
end

function M.start_watchdog(timeout_ms, label)
  local timer = vim.uv.new_timer()
  if not timer then
    M.fail("failed to create watchdog timer for " .. label)
  end

  timer:start(timeout_ms, 0, vim.schedule_wrap(function()
    if timer:is_closing() then
      return
    end
    timer:stop()
    timer:close()
    vim.api.nvim_err_writeln("test watchdog fired: " .. label)
    vim.cmd("cquit 1")
  end))

  return function()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
end

function M.wait_for(label, timeout_ms, predicate)
  local ok = vim.wait(timeout_ms, predicate, 100, false)
  if not ok then
    M.fail("timed out waiting for " .. label)
  end
end

function M.startup_status(bufnr)
  local ok, ark = pcall(require, "ark")
  if not ok then
    return nil
  end

  local status = ark.status({ include_lsp = true })
  return type(status) == "table" and status.startup or nil
end

function M.main_buffer_unlocked(bufnr)
  local startup = M.startup_status(bufnr)
  return type(startup) == "table" and startup.main_buffer_unlocked == true
end

function M.wait_for_main_buffer_unlocked(timeout_ms, bufnr)
  M.wait_for("main buffer unlocked", timeout_ms, function()
    return M.main_buffer_unlocked(bufnr)
  end)
  return M.startup_status(bufnr)
end

function M.tmux(args)
  local command = { "tmux" }
  local explicit_socket = vim.env.ARK_TMUX_SOCKET
  if type(explicit_socket) == "string" and explicit_socket ~= "" then
    command[#command + 1] = "-S"
    command[#command + 1] = explicit_socket
  else
    local tmux_env = vim.env.TMUX
    if type(tmux_env) == "string" and tmux_env ~= "" then
      local socket = vim.split(tmux_env, ",", { plain = true })[1]
      if type(socket) == "string" and socket ~= "" then
        command[#command + 1] = "-S"
        command[#command + 1] = socket
      end
    end
  end

  local output = vim.fn.system(vim.list_extend(command, args))
  if vim.v.shell_error ~= 0 then
    M.fail("tmux command failed: " .. output)
  end
  return output
end

function M.request(client, method, params, timeout_ms)
  local response, err = client:request_sync(method, params, timeout_ms or 10000, 0)
  if err then
    M.fail(method .. " error: " .. err)
  end
  if not response then
    M.fail("no response for " .. method)
  end
  if response.error then
    M.fail(method .. " error: " .. vim.inspect(response.error))
  end
  if response.err then
    M.fail(method .. " error: " .. vim.inspect(response.err))
  end
  return response.result
end

function M.completion_items(result)
  if type(result) ~= "table" then
    return {}
  end
  if vim.islist(result) then
    return result
  end
  return result.items or {}
end

function M.find_item(items, label)
  for _, item in ipairs(items) do
    if item.label == label then
      return item
    end
  end
  return nil
end

function M.item_labels(items)
  local out = {}
  for _, item in ipairs(items) do
    out[#out + 1] = item.label
  end
  return out
end

function M.assert_fresh_detached_lsp_binary(binary_path)
  if type(binary_path) ~= "string" or binary_path == "" then
    return
  end

  local repo_root = vim.fn.getcwd()
  local normalized_binary = vim.fs.normalize(binary_path)
  local normalized_root = vim.fs.normalize(repo_root)

  if not vim.startswith(normalized_binary, normalized_root .. "/target/") then
    return
  end

  if vim.fn.filereadable(normalized_binary) ~= 1 then
    M.fail("detached ark-lsp binary is missing: " .. normalized_binary)
  end

  local binary_mtime = vim.fn.getftime(normalized_binary)
  if type(binary_mtime) ~= "number" or binary_mtime <= 0 then
    M.fail("failed to stat detached ark-lsp binary: " .. normalized_binary)
  end

  local source_paths = vim.fn.systemlist({
    "rg",
    "--files",
    "crates/ark-lsp/src",
    "crates/ark/src",
    "crates/ark_test/src",
  })
  if vim.v.shell_error ~= 0 then
    M.fail("failed to enumerate Rust sources for binary freshness check")
  end

  source_paths[#source_paths + 1] = "crates/ark-lsp/Cargo.toml"
  source_paths[#source_paths + 1] = "crates/ark/Cargo.toml"
  source_paths[#source_paths + 1] = "crates/ark_test/Cargo.toml"
  source_paths[#source_paths + 1] = "Cargo.lock"

  local newer = {}
  for _, relpath in ipairs(source_paths) do
    local fullpath = vim.fs.normalize(repo_root .. "/" .. relpath)
    if vim.fn.filereadable(fullpath) == 1 then
      local source_mtime = vim.fn.getftime(fullpath)
      if type(source_mtime) == "number" and source_mtime > binary_mtime then
        newer[#newer + 1] = relpath
      end
    end
  end

  if #newer > 0 then
    M.fail(
      "detached ark-lsp binary is older than source files: "
        .. table.concat(newer, ", ")
        .. ". Rebuild with: cargo build -p ark-lsp"
    )
  end
end

function M.insert_text(item)
  return item.insertText or item.insert_text
end

function M.assert_no_snippet_items(items, label)
  local snippet_kind = vim.lsp.protocol.CompletionItemKind.Snippet
  local snippet_format = vim.lsp.protocol.InsertTextFormat.Snippet

  for _, item in ipairs(items or {}) do
    if item.kind == snippet_kind
      or item.insertTextFormat == snippet_format
      or item.insert_text_format == snippet_format
    then
      M.fail(string.format("unexpected snippet item for %s: %s", label, vim.inspect(item)))
    end
  end
end

function M.setup_managed_buffer(test_file, lines)
  require("ark").setup({
    auto_start_pane = false,
    auto_start_lsp = false,
    async_startup = false,
    configure_slime = true,
  })

  vim.fn.writefile(lines, test_file)
  vim.cmd("edit " .. test_file)
  vim.cmd("setfiletype r")

  local lsp_config = require("ark").lsp_config(0)
  M.assert_fresh_detached_lsp_binary(lsp_config and lsp_config.cmd and lsp_config.cmd[1] or nil)

  local pane_id, pane_err = require("ark").start_pane()
  if not pane_id then
    M.fail(pane_err or "managed pane id missing")
  end

  M.wait_for("ark bridge ready", 20000, function()
    return require("ark").status().bridge_ready == true
  end)

  require("ark").start_lsp(0)

  M.wait_for("ark lsp client", 15000, function()
    local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
    return client ~= nil and client.initialized == true and not client:is_stopped()
  end)

  M.wait_for("managed R repl ready", 10000, function()
    return require("ark").status().repl_ready == true
  end)

  local client = vim.lsp.get_clients({ bufnr = 0, name = "ark_lsp" })[1]
  return pane_id, client
end

function M.probe_data_table_available(pane_id, setup_cmd)
  M.tmux({
    "send-keys",
    "-t",
    pane_id,
    setup_cmd,
    "Enter",
    "ark_dt_available",
    "Enter",
  })

  M.wait_for("data.table availability probe", 10000, function()
    local capture = M.tmux({ "capture-pane", "-p", "-t", pane_id })
    return capture:find("%[1%] TRUE") ~= nil or capture:find("%[1%] FALSE") ~= nil
  end)

  local capture = M.tmux({ "capture-pane", "-p", "-t", pane_id })
  return capture:find("%[1%] TRUE") ~= nil
end

return M
