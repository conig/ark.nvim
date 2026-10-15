-- Real stdio LSP, deliberately no managed R pane or session bridge. Frontmatter
-- stays useful before runtime hydration and resolves paths from the document.
local root = vim.fn.tempname() .. "-frontmatter"
vim.fn.mkdir(root .. "/chapters", "p")
vim.fn.mkdir(root .. "/references", "p")
vim.fn.writefile({}, root .. "/references/références.bib")
vim.fn.writefile({}, root .. "/references/apa.csl")
vim.fn.writefile({}, root .. "/references/ignore.txt")
local clients = {}
local timings = {}

local function open_document(name, filetype)
  vim.cmd("edit " .. vim.fn.fnameescape(root .. "/chapters/" .. name))
  vim.bo.filetype = filetype
  local id = vim.lsp.start({
    name = "ark_frontmatter_test",
    cmd = { vim.env.ARK_NVIM_LSP_BIN or (vim.fn.getcwd() .. "/target/debug/ark-lsp"), "--runtime-mode", "detached" },
    cmd_env = { ARK_SESSION_STATUS_FILE = "", ARK_SESSION_PORT = "0", ARK_SESSION_AUTH_TOKEN = "" },
    root_dir = root,
  })
  assert(id, "failed to start detached LSP")
  clients[id] = true
  assert(vim.wait(10000, function()
    local client = vim.lsp.get_client_by_id(id)
    return client and client.initialized and vim.lsp.buf_is_attached(0, id)
  end, 20), "LSP initialize timeout")
  return vim.lsp.get_client_by_id(id)
end

local function complete(client, cursor_text)
  local marker = assert(cursor_text:find("@", 1, true))
  local before = cursor_text:sub(1, marker - 1)
  local lines = vim.split(before, "\n", { plain = true })
  local position = { line = #lines - 1, character = vim.str_utfindex(lines[#lines], "utf-16") }
  local text = cursor_text:sub(1, marker - 1) .. cursor_text:sub(marker + 1)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(text, "\n", { plain = true }))
  local started = vim.uv.hrtime()
  local response, err = client:request_sync("textDocument/completion", {
    textDocument = vim.lsp.util.make_text_document_params(0), position = position,
  }, 3000, vim.api.nvim_get_current_buf())
  timings[#timings + 1] = (vim.uv.hrtime() - started) / 1e6
  assert(response and not err and not response.err, vim.inspect(err or response))
  local result = response.result or {}
  return result.items or result, result
end

local function find(items, label)
  for _, item in ipairs(items) do
    if item.label == label then return item end
  end
  error("missing " .. label .. ": " .. vim.inspect(items))
end

local ok, err = xpcall(function()
  local client = open_document("paper.Rmd", "rmd")
  local items = complete(client, '---\nbibliography: ["existing.bib", "../references/ré@"]\n---\n')
  assert(#items == 1, vim.inspect(items))
  local item = find(items, "../references/références.bib")
  assert(item.textEdit.newText == "../references/références.bib", vim.inspect(item))
  assert(item.textEdit.range.start.character == 32, vim.inspect(item.textEdit))
  items = complete(client, "---\nbibliography:\n  - '../references/@'\n---\n")
  assert(#items == 1, vim.inspect(items))
  find(items, "../references/références.bib")
  items = complete(client, "---\ncsl: '../references/@'\n---\n")
  assert(#items == 1, vim.inspect(items))
  find(items, "../references/apa.csl")
  items = complete(client, "---\noutput: papaja::ap@\n---\n")
  find(items, "papaja::apa6_pdf")
  items = complete(client, "---\noutput:\n  papaja::apa6_pdf:\n    keep_@\n---\n")
  assert(find(items, "keep_tex").textEdit.newText == "keep_tex: ")

  -- A bounded list must ask Blink/LSP clients to requery after prefix changes,
  -- otherwise the omitted names can remain invisible in the client cache.
  vim.fn.mkdir(root .. "/many", "p")
  for index = 1, 300 do vim.fn.writefile({}, root .. "/many/ref" .. index .. ".bib") end
  local capped, response = complete(client, "---\nbibliography: '../many/@'\n---\n")
  assert(#capped == 256, "path completion budget was not enforced")
  assert(response.isIncomplete == true, "truncated file candidates must advertise isIncomplete")
  local seen = {}
  for _, candidate in ipairs(capped) do seen[candidate.label] = true end
  for index = 1, 300 do
    local label = "../many/ref" .. index .. ".bib"
    if not seen[label] then
      find(complete(client, "---\nbibliography: '" .. label .. "@'\n---\n"), label)
      break
    end
  end

  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "---", 'bibliography: "../references/références.bib"', "csl: missing.csl", "---", "",
  })
  assert(vim.wait(10000, function()
    for _, diagnostic in ipairs(vim.diagnostic.get(0)) do
      if diagnostic.code == "frontmatter-missing-file" and diagnostic.lnum == 2 then return true end
    end
  end, 30), "missing-file diagnostic did not arrive through LSP")
  for _, diagnostic in ipairs(vim.diagnostic.get(0)) do
    assert(diagnostic.code ~= "frontmatter-missing-file" or diagnostic.lnum == 2, vim.inspect(diagnostic))
  end

  vim.bo.modified = false
  client = open_document("paper.qmd", "quarto")
  items = complete(client, "---\nformat: ht@\n---\n")
  find(items, "html")
  for _, candidate in ipairs(items) do assert(candidate.label ~= "html_document") end
  items = complete(client, "---\nformat:\n  html:\n    code-@\n---\n")
  find(items, "code-fold")
  for _, candidate in ipairs(items) do assert(candidate.label ~= "code_folding") end
  table.sort(timings)
  assert(timings[math.ceil(#timings / 2)] < 250, "static completion must not wait for a runtime timeout")
  print(vim.json.encode({ frontmatter_completion_ms = timings, median_ms = timings[math.ceil(#timings / 2)] }))
end, debug.traceback)
for id in pairs(clients) do
  local client = vim.lsp.get_client_by_id(id)
  if client then client:stop(true) end
end
vim.fn.delete(root, "rf")
if not ok then error(err, 0) end
