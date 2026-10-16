vim.opt.rtp:prepend(vim.fn.getcwd())

local ark_test = dofile(vim.fs.normalize(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua"))
local stop_watchdog = ark_test.start_watchdog(60000, "nvim_console_help_first_request")
local repo_root = vim.fn.getcwd()
local ark = require("ark")
local console = require("ark.console")

ark.setup({
  auto_start_pane = false,
  auto_start_lsp = true,
  help = { display = "float" },
  terminal = {
    launcher = repo_root .. "/scripts/ark-r-launcher.sh",
    startup_status_dir = ark_test.run_tmpdir() .. "/status",
    session_pkg_path = repo_root .. "/packages/arkbridge",
  },
})

local bufnr = assert(ark.console())
local ok, err = xpcall(function()
  ark_test.wait_for("console prompt and hydrated LSP", 30000, function()
    local status = console.status(bufnr)
    local client = vim.lsp.get_clients({ bufnr = bufnr, name = "ark_lsp" })[1]
    if not status or status.prompt_state ~= "top-level" or not client or not client.initialized then
      return false
    end
    local response = client:request_sync("ark/internal/status", {}, 1000, bufnr)
    local detached = response and response.result and response.result.detachedSessionStatus
    return detached and tonumber(detached.lastBootstrapSuccessMs) ~= nil
  end)

  -- R acknowledges the help RPC before returning to its prompt. Typing with
  -- Blink active exposed this race; the short post-hook sleep makes that real
  -- boundary deterministic without mocking the hook, RPC, LSP, or busy gate.
  local status = console.status(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, status.input_start, -1, false, {
    "local({ ?citation; Sys.sleep(0.3) })",
  })
  assert(console.submit(bufnr))

  local help_bufnr
  local opened = vim.wait(10000, function()
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
      local candidate = vim.api.nvim_win_get_buf(winid)
      if vim.b[candidate].ark_help_buffer == true then
        help_bufnr = candidate
        return true
      end
    end
    return false
  end, 50, false)
  assert(
    opened,
    "the first console ?citation must open ArkHelp without resubmission; messages: " .. vim.fn.execute("messages")
  )
  local text = table.concat(vim.api.nvim_buf_get_lines(help_bufnr, 0, -1, false), "\n")
  assert(text:find("Citing R and R Packages", 1, true), "expected the citation help page, got: " .. text)
  assert(console.status(bufnr).prompt_state == "top-level", "help must wait for R's prompt, not query a busy session")
  assert(not vim.fn.execute("messages"):find("no help text found", 1, true), "first help lookup should not warn")
end, debug.traceback)

console.stop(bufnr)
stop_watchdog()
assert(ok, err)
vim.print({ nvim_console_help_first_request = "ok" })
