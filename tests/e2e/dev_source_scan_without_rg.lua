vim.opt.rtp:prepend(vim.fn.getcwd())

package.loaded["ark.dev"] = nil

local original_executable = vim.fn.executable
vim.fn.executable = function(path)
  if path == "rg" then
    return 0
  end
  return original_executable(path)
end

local ok, err = xpcall(function()
  local paths = require("ark.dev").rust_source_paths()
  local expected = vim.fs.normalize(vim.fn.getcwd() .. "/crates/ark-lsp-core/src/lib.rs")
  if not vim.tbl_contains(paths, expected) then
    error("Rust source discovery omitted product sources when rg was unavailable: " .. vim.inspect(paths), 0)
  end
end, debug.traceback)

vim.fn.executable = original_executable
package.loaded["ark.dev"] = nil

if not ok then
  error(err, 0)
end
