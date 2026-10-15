local result = vim.system({ "Rscript", "tests/e2e/ark_view_values_bridge.R" }, { text = true }):wait(30000)
assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
print(result.stdout)
