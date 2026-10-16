-- Real stdio LSP + installed arbitrary output package; no managed R session.
-- Renderer bodies/default expressions must never run during discovery.
local t = require("ark_test")
local root = t.run_tmpdir() .. "/renderer-discovery"
local package_dir, library = root .. "/arkschemafixture", root .. "/library"
vim.fn.mkdir(package_dir .. "/R", "p")
vim.fn.mkdir(library, "p")
vim.fn.writefile({
  "Package: arkschemafixture",
  "Version: 0.0.1",
  "Title: Renderer Discovery Fixture",
  "Description: Tests static renderer discovery.",
  "License: MIT",
  "Author: Ark",
  "Maintainer: Ark <ark@example.invalid>",
}, package_dir .. "/DESCRIPTION")
vim.fn.writefile({ "export(wrapper)", "export(other)" }, package_dir .. "/NAMESPACE")
vim.fn.writefile({
  '.onLoad <- function(...) { Sys.sleep(0.6); cat("fixture namespace loaded\\n") }',
  'base_format <- function(extra = TRUE, engine = c("alpha", "beta", "true"), fixed = FALSE, dangerous = stop("must not force defaults")) {',
  "  engine <- match.arg(engine)",
  '  stop("must not invoke renderer")',
  "}",
  "forward <- function(..., base_format = base_format) do.call(base_format, list(fixed = TRUE, ...))",
  'metadata_reader <- function(metadata) { if (isTRUE(metadata$customflag)) stop("must not execute metadata reader") }',
  "wrapper <- function(own = FALSE, ...) {",
  "  pre_processor <- function(metadata, ...) metadata_reader(metadata)",
  "  forward(..., base_format = base_format)",
  "}",
  'other <- function(other_option = TRUE) stop("must not execute other renderer")',
}, package_dir .. "/R/formats.R")
local skeleton = package_dir .. "/inst/rmarkdown/templates/custom/skeleton"
vim.fn.mkdir(skeleton, "p")
vim.fn.writefile({
  "---",
  "output: arkschemafixture::wrapper",
  'shorttitle: "A title"',
  "masked: false",
  "author:",
  '  - name: "Example"',
  "    corresponding: true",
  "---",
  "",
}, skeleton .. "/skeleton.Rmd")
local installed = vim
  .system({ "R", "CMD", "INSTALL", "--no-docs", "--no-help", "--no-test-load", "-l", library, package_dir }, { text = true })
  :wait()
assert(installed.code == 0, installed.stderr)
require("ark").setup({ auto_start_pane = false, auto_start_lsp = false })
vim.cmd("edit " .. vim.fn.fnameescape(root .. "/paper.Rmd"))
vim.bo.filetype = "rmd"
local id = assert(vim.lsp.start({
  name = "ark_renderer_test",
  cmd = { vim.env.ARK_NVIM_LSP_BIN or (vim.fn.getcwd() .. "/target/debug/ark-lsp"), "--runtime-mode", "detached" },
  cmd_env = { ARK_SESSION_STATUS_FILE = "", ARK_SESSION_PORT = "0", ARK_SESSION_AUTH_TOKEN = "", R_LIBS = library },
  root_dir = root,
}))
t.wait_for("renderer LSP", 10000, function()
  return vim.lsp.get_client_by_id(id).initialized and vim.lsp.buf_is_attached(0, id)
end)
local client = vim.lsp.get_client_by_id(id)
local function completion(text)
  local marker = assert(text:find("|", 1, true))
  local before = vim.split(text:sub(1, marker - 1), "\n", { plain = true })
  vim.api.nvim_buf_set_lines(
    0,
    0,
    -1,
    false,
    vim.split(text:sub(1, marker - 1) .. text:sub(marker + 1), "\n", { plain = true })
  )
  local started = vim.uv.hrtime()
  local response, err = client:request_sync("textDocument/completion", {
    textDocument = vim.lsp.util.make_text_document_params(0),
    position = { line = #before - 1, character = #before[#before] },
  }, 3000, vim.api.nvim_get_current_buf())
  assert(response and not err and not response.err and not response.error, vim.inspect(err or response))
  return t.completion_items(response.result), (vim.uv.hrtime() - started) / 1e6
end
local function find(items, label)
  return t.find_item(items, label)
end
local base = "---\noutput: arkschemafixture::wrapper\n"
-- Opening/editing the selected output starts discovery without making this
-- first completion request wait for Rscript or package loading.
local _, cold_ms = completion(base .. "sho|\n---\n")
assert(cold_ms < 250, "cold completion blocked on renderer discovery: " .. cold_ms)
local found
assert(
  vim.wait(15000, function()
    found = completion(base .. "sho|\n---\n")
    return find(found, "shorttitle") ~= nil
  end, 100),
  "selected arbitrary renderer did not discover skeleton metadata"
)
local items = completion("---\noutput:\n  arkschemafixture::wrapper:\n    ex|\n---\n")
assert(find(items, "extra"), "wrapper forwarding did not expose inherited options: " .. vim.inspect(items))
assert(not find(items, "fixed"), "fixed forwarded arguments must not be exposed")
items = completion("---\noutput:\n  arkschemafixture::wrapper:\n    engine: 'b|'\n---\n")
assert(find(items, "beta"), "match.arg choices were not discovered")
items = completion(base .. "masked: |\n---\n")
assert(find(items, "true") and find(items, "false"), "template boolean values missing")
items = completion(base .. "author:\n  - name: Someone\n    cor|\n---\n")
assert(find(items, "corresponding"), "nested template metadata missing")
items = completion(base .. "custom|\n---\n")
assert(find(items, "customflag"), "preprocessor metadata access was not discovered")
local warm_timings = {}
for _ = 1, 10 do
  local _, warm_ms = completion(base .. "sho|\n---\n")
  warm_timings[#warm_timings + 1] = warm_ms
  assert(warm_ms < 250, "warm renderer completion blocked: " .. warm_ms)
end
local large = { base }
for index = 1, 1500 do
  large[#large + 1] = "extra_metadata_" .. index .. ": value\n"
end
local large_items, large_ms = completion(table.concat(large) .. "sho|\n---\n")
assert(find(large_items, "shorttitle") and large_ms < 250, "large frontmatter completion stalled: " .. large_ms)
items = completion(base .. "shorttitle: Existing\nsho|\n---\n")
assert(not find(items, "shorttitle"), "already-declared metadata key was offered again")
items = completion("---\noutput:\n  arkschemafixture::wrapper:\n    engine: tr|\n---\n")
assert(find(items, "true").textEdit.newText == '"true"', "string choices must not become YAML booleans")
local multiple = "---\noutput:\n  arkschemafixture::wrapper: default\n  arkschemafixture::other: default\n"
assert(find(completion(multiple .. "sho|\n---\n"), "shorttitle"), "multiple outputs lost renderer metadata")
assert(
  vim.wait(15000, function()
    items =
      completion("---\noutput:\n  arkschemafixture::wrapper: default\n  arkschemafixture::other:\n    other_|\n---\n")
    return find(items, "other_option") ~= nil
  end, 100),
  "second output schema missing"
)
assert(not find(items, "extra"), "options leaked between output mappings")
-- Changing output must stop leaking the previous renderer's fields immediately.
items = completion("---\noutput: arkschemafixture::other\nsho|\n---\n")
assert(not find(items, "shorttitle"), "schema leaked across output selection")
items = completion("---\noutput: arkschemafixture::missing\nsho|\n---\n")
assert(not find(items, "shorttitle"), "missing output must silently use ordinary completion")
if vim.env.ARK_TEST_RENDERER_PAPAJA == "1" then
  local papaja = "---\noutput: papaja::apa6_pdf\n"
  assert(
    vim.wait(15000, function()
      return find(completion(papaja .. "short|\n---\n"), "shorttitle") ~= nil
    end, 100),
    "papaja metadata missing"
  )
  assert(find(completion(papaja .. "authorn|\n---\n"), "authornote"))
  assert(find(completion(papaja .. "mask: |\n---\n"), "false"))
  assert(find(completion("---\noutput:\n  papaja::apa6_pdf:\n    latex_engine: x|\n---\n"), "xelatex"))
end
client:stop(true)
vim.print({
  frontmatter_renderer_discovery = "ok",
  cold_ms = cold_ms,
  warm_ms = warm_timings,
  large_header_ms = large_ms,
})
