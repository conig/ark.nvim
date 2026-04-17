local ark_test = require("ark_test")

local function diagnostic_entries()
  local entries = {}

  for _, diagnostic in ipairs(vim.diagnostic.get(0)) do
    entries[#entries + 1] = {
      lnum = diagnostic.lnum,
      message = diagnostic.message,
    }
  end

  table.sort(entries, function(lhs, rhs)
    if lhs.lnum == rhs.lnum then
      return lhs.message < rhs.message
    end

    return lhs.lnum < rhs.lnum
  end)

  return entries
end

-- Regression scenario: Neovim should publish explicit missing-package
-- diagnostics for bare package names in `library()` and `require()` once Ark's
-- semantic diagnostics are hydrated.
local package_name = "arkmissingpackagediagnosticzz"
local diagnostic_message = string.format("Package '%s' is not installed.", package_name)
local test_file = "/tmp/ark_library_missing_package_diagnostics.R"

ark_test.setup_managed_buffer(test_file, {
  string.format("library(%s)", package_name),
  string.format("require(%s)", package_name),
})

require("ark").refresh(0)

local settled = vim.wait(10000, function()
  local entries = diagnostic_entries()
  return #entries == 2
    and entries[1].lnum == 0
    and entries[1].message == diagnostic_message
    and entries[2].lnum == 1
    and entries[2].message == diagnostic_message
end, 100, false)

local entries = diagnostic_entries()
if not settled then
  ark_test.fail(vim.inspect({
    diagnostics = entries,
    status = require("ark").status({ include_lsp = true }),
  }))
end

vim.print({
  diagnostics = entries,
  status = require("ark").status({ include_lsp = true }),
})
