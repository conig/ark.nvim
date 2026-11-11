vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/snacks.nvim")
local snacks = require("snacks")
if vim.env.ARK_TEST_NVIM_INIT == "NONE" then
    snacks.setup({ picker = { enabled = true } })
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.fn.mkdir(tmp .. "/_target_pipelines", "p")
vim.fn.writefile({
    "source('_target_pipelines/report.R')",
    "list(",
    "  targets::tar_target(a, report),",
    "  targets::tar_target(weekly_quality_report_archive, build()),",
    "  targets::tar_target(report, build()),",
    "  targets::tar_target(z, archive)",
    ")",
}, tmp .. "/_targets.R")
vim.fn.writefile({ "targets::tar_target(b, build())" }, tmp .. "/_target_pipelines/report.R")
local source = vim.fn.bufadd(tmp .. "/notes.txt")
local controller = require("ark.target_actions").new({
    resolve_bufnr = function(bufnr)
        return bufnr
    end,
    target_tools = require("ark.targets"),
})

local picker
local ok, err = xpcall(function()
    assert(controller.targets_pick(source))
    picker = snacks.picker.get()[1]
    assert(picker, "target picker did not open")

    local function search(pattern)
        picker.input:set(pattern)
        local done = false
        picker:find({
            on_done = function()
                done = true
            end,
        })
        assert(
            vim.wait(3000, function()
                return done
            end, 10),
            "target matching timed out"
        )
        return vim.tbl_map(function(item)
            return item.name
        end, picker:items())
    end

    -- A short exact command match used to beat a longer target-name match.
    -- Exercise the real Snacks matcher/sorter, not just the picker options.
    local names = search("report")
    assert(names[1] == "report" and names[2] == "weekly_quality_report_archive", vim.inspect(names))
    assert(vim.tbl_contains(names, "a") and vim.tbl_contains(names, "b"), vim.inspect(names))
    for _, pattern in ipairs({ "rprt", "'report" }) do
        local matches = search(pattern)
        assert(matches[1] == "report" and matches[2] == "weekly_quality_report_archive", vim.inspect(matches))
    end
    assert(vim.deep_equal(search("name:report"), { "report", "weekly_quality_report_archive" }))
    assert(vim.deep_equal(search("quality archive"), { "weekly_quality_report_archive" }))
    assert(vim.deep_equal(search("REPORT"), {}))
    assert(vim.deep_equal(search("^report"), { "report" }))
    assert(vim.deep_equal(search("_target_pipelines"), { "b" }))
    -- Commands remain searchable when no target name matches.
    local command_matches = search("build")
    table.sort(command_matches)
    assert(
        vim.deep_equal(command_matches, { "b", "report", "weekly_quality_report_archive" }),
        vim.inspect(command_matches)
    )
    -- Re-querying must not reuse name ranks from a previous pattern.
    assert(vim.deep_equal(search("archive"), { "weekly_quality_report_archive", "z" }))
    assert(vim.deep_equal(search("report"), names))
    assert(vim.deep_equal(search(""), { "a", "b", "report", "weekly_quality_report_archive", "z" }))
end, debug.traceback)
if picker then
    picker:close()
end
vim.api.nvim_buf_delete(source, { force = true })
vim.fn.delete(tmp, "rf")
assert(ok, err)
