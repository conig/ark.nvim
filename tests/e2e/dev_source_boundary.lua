local paths = require("ark.dev").rust_source_paths()
local saw_lsp_core = false
for _, path in ipairs(paths) do
  if path:find("/crates/ark/src/", 1, true) then
    error("inactive upstream ark crate entered product freshness inputs: " .. path, 0)
  end
  if path:find("/crates/ark%-lsp%-core/src/") then
    saw_lsp_core = true
  end
end
assert(saw_lsp_core, vim.inspect(paths))
