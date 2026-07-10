vim.opt.rtp:prepend(vim.fn.getcwd())

local lsp_calls = {}

package.loaded["ark.blink"] = {
  ensure_integration = function() end,
  handle_insert_char_pre = function() end,
}

package.loaded["ark.bridge"] = {
  ensure_current_runtime = function()
    return true
  end,
  build_session_runtime = function()
    return true
  end,
}

package.loaded["ark.config"] = {
  assert_valid = function() end,
  defaults = function()
    return {
      async_startup = false,
      auto_start_lsp = false,
      auto_start_pane = false,
      filetypes = { "r" },
    }
  end,
}

package.loaded["ark.dev"] = {
  build_detached_lsp = function()
    return true
  end,
}

package.loaded["ark.session"] = {
  runtime_config = function()
    return nil
  end,
  start = function()
    return "pane"
  end,
  status = function()
    return { bridge_ready = true }
  end,
  stop = function() end,
}

package.loaded["ark.lsp"] = {
  set_startup_ready_callback = function() end,
  start = function() end,
  sync_sessions = function() end,
  status = function()
    return {
      available = true,
      sessionBridgeConfigured = true,
      detachedSessionStatus = {
        lastSessionUpdateStatus = "ready",
      },
    }
  end,
  targets_network = function(_, bufnr, project)
    lsp_calls[#lsp_calls + 1] = { name = "network", bufnr = bufnr, project = project }
    return {
      project = { root = project.root },
      source = "targets::tar_network()",
      edges = {
        { from = "raw_data", to = "clean_data" },
        { from = "clean_data", to = "report" },
      },
    }
  end,
  targets_meta = function(_, bufnr, project, names)
    lsp_calls[#lsp_calls + 1] = { name = "meta", bufnr = bufnr, project = project, names = names }
    return {
      project = { root = project.root },
      meta = {
        {
          name = "clean_data",
          progress = "built",
          seconds = 1.25,
          bytes = 128,
          format = "rds",
        },
      },
    }
  end,
}

package.loaded["ark.snippets"] = {
  open = function() end,
}

package.loaded["ark.view"] = {
  open = function() end,
  refresh = function() end,
  close = function() end,
}

local source_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(source_buf)
vim.api.nvim_buf_set_name(source_buf, vim.fn.getcwd() .. "/_targets.R")
vim.bo[source_buf].filetype = "r"

local ark = require("ark")

local graph = ark.targets_graph(source_buf)
if type(graph) ~= "table" or not vim.api.nvim_buf_is_valid(graph.bufnr) then
  error("target graph did not open a view buffer", 0)
end

local graph_lines = table.concat(vim.api.nvim_buf_get_lines(graph.bufnr, 0, -1, false), "\n")
if not graph_lines:find("# Ark Target Graph", 1, true) then
  error("target graph view is missing its title: " .. graph_lines, 0)
end
if not graph_lines:find("raw_data -> clean_data", 1, true) then
  error("target graph view is missing an edge: " .. graph_lines, 0)
end
if vim.bo[graph.bufnr].buftype ~= "nofile" or vim.bo[graph.bufnr].readonly ~= true then
  error("target graph view buffer is not read-only nofile", 0)
end

local second_graph = ark.targets_graph(source_buf)
if type(second_graph) ~= "table" or not vim.api.nvim_buf_is_valid(second_graph.bufnr) then
  error("target graph did not open a second view buffer", 0)
end
if vim.api.nvim_buf_get_name(second_graph.bufnr) == vim.api.nvim_buf_get_name(graph.bufnr) then
  error("target graph reused a duplicate view buffer name", 0)
end

local status = ark.targets_status("clean_data, report", source_buf)
if type(status) ~= "table" or not vim.api.nvim_buf_is_valid(status.bufnr) then
  error("target status did not open a view buffer", 0)
end

local status_lines = table.concat(vim.api.nvim_buf_get_lines(status.bufnr, 0, -1, false), "\n")
if not status_lines:find("# Ark Target Status", 1, true) then
  error("target status view is missing its title: " .. status_lines, 0)
end
if not status_lines:find("## clean_data", 1, true) then
  error("target status view is missing target metadata: " .. status_lines, 0)
end

local status_call = lsp_calls[#lsp_calls]
if status_call.name ~= "meta" or not vim.deep_equal(status_call.names, { "clean_data", "report" }) then
  error("target status did not normalize names for metadata: " .. vim.inspect(status_call), 0)
end

local log = ark.targets_log("clean_data", source_buf)
if type(log) ~= "table" or not vim.api.nvim_buf_is_valid(log.bufnr) then
  error("target log did not open a view buffer", 0)
end

local log_lines = table.concat(vim.api.nvim_buf_get_lines(log.bufnr, 0, -1, false), "\n")
if not log_lines:find("# Ark Target Log", 1, true) then
  error("target log view is missing its title: " .. log_lines, 0)
end

local expected_calls = { "network", "network", "meta", "meta" }
for index, expected in ipairs(expected_calls) do
  if not lsp_calls[index] or lsp_calls[index].name ~= expected then
    error("unexpected target view bridge calls: " .. vim.inspect(lsp_calls), 0)
  end
end
