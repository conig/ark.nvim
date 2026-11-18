local ark_test = require("ark_test")
local root = ark_test.run_tmpdir()
local client

local function complete(input, trigger)
  local cursor = assert(input:find("@", 1, true))
  local before = vim.split(input:sub(1, cursor - 1), "\n", { plain = true })
  local lines = vim.split((input:gsub("@", "", 1)), "\n", { plain = true })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  local response, err = client:request_sync("textDocument/completion", {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = #before - 1, character = vim.str_utfindex(before[#before], client.offset_encoding) },
    context = trigger and { triggerKind = 2, triggerCharacter = trigger } or { triggerKind = 1 },
  }, 3000, vim.api.nvim_get_current_buf())
  assert(response and not err and not response.err, vim.inspect(err or response))
  return ark_test.completion_items(response.result)
end

local function apply(item)
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  vim.lsp.util.apply_text_edits({ item.textEdit }, scratch, client.offset_encoding)
  local text = table.concat(vim.api.nvim_buf_get_lines(scratch, 0, -1, false), "\n")
  vim.api.nvim_buf_delete(scratch, {})
  return text
end

for _, document in ipairs({
  { name = "paper.Rmd", filetype = "rmd" },
  { name = "paper.qmd", filetype = "quarto" },
}) do
  vim.cmd("edit! " .. vim.fn.fnameescape(root .. "/" .. document.name))
  vim.bo.filetype = document.filetype
  local id = assert(vim.lsp.start({
    name = "ark_math_test",
    cmd = { vim.env.ARK_NVIM_LSP_BIN or (vim.fn.getcwd() .. "/target/debug/ark-lsp"), "--runtime-mode", "detached" },
    cmd_env = { ARK_SESSION_STATUS_FILE = "", ARK_SESSION_PORT = "0", ARK_SESSION_AUTH_TOKEN = "" },
    root_dir = root,
  }))
  ark_test.wait_for("detached LSP initialize", 10000, function()
    client = vim.lsp.get_client_by_id(id)
    return client and client.initialized and vim.lsp.buf_is_attached(0, id)
  end)

  local triggers = client.server_capabilities.completionProvider.triggerCharacters
  assert(vim.tbl_contains(triggers, "\\"), "missing TeX command trigger")
  assert(ark_test.find_item(complete([[$\@$]], "\\"), "\\kappa"), "backslash did not offer math commands")
  local items = complete([[café 🧪: $\k@ap$]])
  local item = assert(ark_test.find_item(items, "\\kappa"), vim.inspect(items))
  assert(apply(item) == [[café 🧪: $\kappa$]], "bad UTF-16 or suffix edit")
  assert(ark_test.find_item(complete("$$\n\\sq@\n$$"), "\\sqrt"), "missing display completion")
  item = assert(ark_test.find_item(complete([[$\kap@]]), "\\kappa"), "missing unfinished inline completion")
  assert(apply(item) == [[$\kappa$]], "acceptance did not close unfinished inline math")
  assert(#complete("$@", "$") == 0, "math menu should not open on a dollar")
  assert(#complete([[Prose \@]], "\\") == 0, "backslash triggered completions outside math")
  assert(#complete("```{r}\nx <- \\@\n```", "\\") == 0, "backslash triggered completions in R code")
  for _, input in ipairs({
    [[Prose \kap@]], [[\$20 \kap@]], [[It costs $20 and $30 \kap@]], [[$x$ \kap@]],
    "---\ntitle: '$\\kap@'\n---", "`r '$\\kap@'`", "```\n$\\kap@\n```",
  }) do
    assert(not ark_test.find_item(complete(input), "\\kappa"), "leaked math completion: " .. input)
  end
  local r_items = complete("```{r}\nTRU@\n```")
  assert(ark_test.find_item(r_items, "TRUE"), "ordinary fenced R completion stopped working")
end

client:stop(true)
