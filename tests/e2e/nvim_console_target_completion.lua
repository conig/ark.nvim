local ark_test = require("ark_test")
local repo = vim.fs.normalize(vim.env.ARK_REPO_ROOT or vim.fn.getcwd())
local root = vim.fs.normalize(ark_test.run_tmpdir() .. "/console-target-completion")
vim.fn.mkdir(root .. "/_target_pipelines", "p")
vim.fn.writefile({ "Package: consolecompletion", "Version: 0.0.0" }, root .. "/DESCRIPTION")
vim.fn.writefile({
  -- Real projects can take longer than the bridge deadline just to evaluate
  -- their manifest. Typing a target name must use the static workspace index.
  "Sys.sleep(2)",
  'targets::tar_source("_target_pipelines")',
  "manuscript_targets",
}, root .. "/_targets.R")
vim.fn.writefile({
  "manuscript_targets <- list(",
  "  targets::tar_target(manuscript_pdf, 1),",
  "  targets::tar_target(manuscript_docx, 2),",
  "  targets::tar_target(manuscript_plain_text, 3))",
}, root .. "/_target_pipelines/manuscript_targets.R")
vim.cmd("cd " .. vim.fn.fnameescape(root))
local ark = require("ark")
ark.setup({
  auto_start_pane = false,
  auto_start_lsp = true,
  async_startup = false,
  terminal = {
    launcher = repo .. "/scripts/ark-r-launcher.sh",
    startup_status_dir = ark_test.run_tmpdir() .. "/status",
    session_pkg_path = repo .. "/packages/arkbridge",
  },
})
local bufnr = assert(ark.console())
ark_test.wait_for("console bridge hydration", 30000, function()
  local client = vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp" })[1]
  if not client or not client.initialized then
    return false
  end
  local response = client:request_sync("ark/internal/status", {}, 1000, bufnr)
  local status = response and response.result
  return status and status.detachedSessionStatus and tonumber(status.detachedSessionStatus.lastBootstrapSuccessMs)
end)
local client = vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp" })[1]
local function complete(text)
  local column = assert(text:find("|", 1, true)) - 1
  text = text:gsub("|", "")
  local status = require("ark.console").status(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, { text })
  -- Let the real console/LSP didChange debounce observe the edit, as it does
  -- between typing and the completion menu opening in an interactive editor.
  vim.wait(250, function()
    return false
  end, 250)
  local result = ark_test.request(client, "textDocument/completion", {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = { line = status.input_start, character = column },
    context = { triggerKind = 1 },
  }, 10000)
  return ark_test.completion_items(result)
end

-- No source buffer is opened in this Neovim: the managed tmux console runs in
-- its own editor process. Its virtual URI must still resolve the project.
for _, text in ipairs({ "tar_make(ma|)", "targets::tar_make(names = ma|)", "tar_load(c(ma|))" }) do
  local items = complete(text)
  for _, name in ipairs({ "manuscript_pdf", "manuscript_docx", "manuscript_plain_text" }) do
    local item = ark_test.find_item(items, name)
    assert(
      item and item.detail == "targets target",
      text .. " missing indexed target " .. name .. ": " .. vim.inspect(ark_test.item_labels(items))
    )
    assert(ark_test.insert_text(item) == name, "target completion must insert a bare target name")
  end
end
assert(require("ark.console").stop(bufnr))
vim.print({ nvim_console_target_completion = "ok" })
