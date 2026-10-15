-- An explicit preview must inspect the real on-disk pipeline without building,
-- blocking Neovim, requiring a managed R session, or swallowing stale buffers.
vim.opt.rtp:prepend(vim.fn.getcwd())
local ark_test = dofile(vim.fn.getcwd() .. "/tests/e2e/ark_test.lua")
local stop_watchdog = ark_test.start_watchdog(60000, "targets_rebuild_preview")
require("ark").setup({ auto_start_pane = false, auto_start_lsp = false, configure_slime = false })
vim.cmd("runtime plugin/ark.lua")
require("ark.session").start = function()
  error("preview must not start the managed R session")
end
local root = ark_test.run_tmpdir() .. "/preview-project"
vim.fn.mkdir(root, "p")
local project = { root = root, script = root .. "/pipeline.R", store = root .. "/custom-store" }
local function script(value, prefix)
  return {
    prefix or "",
    "library(targets)",
    "list(",
    "tar_target(raw, {Sys.sleep(0.02); " .. value .. "}),",
    "tar_target(clean, raw + 1),",
    "tar_target(manuscript, {writeLines('built', 'build-sentinel'); clean * 2}),",
    "tar_target(unrelated, 42))",
  }
end
vim.fn.writefile(script("1"), project.script)
local setup = vim.fn.system({
  "Rscript",
  "--vanilla",
  "-e",
  string.format(
    "setwd(%s); targets::tar_make(script='pipeline.R',store='custom-store',callr_function=NULL,reporter='silent')",
    vim.json.encode(root)
  ),
})
assert(vim.v.shell_error == 0, "cannot build fixture: " .. setup)
vim.fn.delete(root .. "/build-sentinel")
vim.fn.writefile({ "options(ark.preview.project.profile = TRUE)" }, root .. "/.Rprofile")
vim.fn.writefile({ "ARK_PREVIEW_PROJECT_ENV=project" }, root .. "/.Renviron")
local slow_prefix =
  "stopifnot(isTRUE(getOption('ark.preview.project.profile')), Sys.getenv('ARK_PREVIEW_PROJECT_ENV') == 'project'); Sys.sleep(0.4)"
vim.fn.writefile(script("2", slow_prefix), project.script)
local source = vim.fn.bufadd(project.script)
vim.fn.bufload(source)
vim.bo[source].filetype = "r"
vim.api.nvim_buf_set_lines(source, 0, 1, false, { "# unsaved edit, not evaluated" })
vim.api.nvim_set_current_buf(source)
vim.fn.writefile({ "main:", "  script: pipeline.R", "  store: custom-store" }, root .. "/_targets.yaml")

-- Exercise discovery + literal name parsing at the real public command boundary,
-- rather than only handing the worker a pre-resolved project. No R/LSP session
-- is available, and session.start above fails if this path tries to create one.
assert(
  vim.tbl_contains(vim.fn.getcompletion("Ark targets pre", "cmdline"), "targets preview"),
  "canonical command completion is missing targets preview"
)
local source_win = vim.api.nvim_get_current_win()
local public_dispatch_ms = 0
local function public_result(command, count)
  vim.api.nvim_set_current_win(source_win)
  local invoked = vim.uv.hrtime()
  if type(command) == "string" then
    vim.cmd(command)
  else
    local opened = assert(require("ark").targets_preview(command, source))
    assert(opened.bufnr == vim.api.nvim_get_current_buf(), "public API did not open a preview")
  end
  local elapsed = (vim.uv.hrtime() - invoked) / 1e6
  public_dispatch_ms = math.max(public_dispatch_ms, elapsed)
  assert(elapsed < 100, "public preview entrypoint blocked the editor: " .. elapsed .. " ms")
  local preview_buf = vim.api.nvim_get_current_buf()
  assert(preview_buf ~= source, "preview command did not open its view")
  local text
  assert(
    vim.wait(10000, function()
      text = table.concat(vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false), "\n")
      return text:find("targets in scope", 1, true) or text:find("Preview unavailable", 1, true)
    end, 10),
    "public preview never completed"
  )
  assert(text:find("3 outdated / " .. count .. " targets in scope", 1, true), text)
  assert(text:find("raw -> clean", 1, true) and text:find("unsaved", 1, true), text)
  assert(vim.fn.filereadable(root .. "/build-sentinel") == 0, "public preview executed a target")
  assert(vim.bo[source].modified, "public preview saved the source buffer")
  vim.api.nvim_buf_delete(preview_buf, { force = true })
end
public_result("Ark targets preview manuscript, unrelated", 4)
public_result("ArkTargetsPreview manuscript", 3)
public_result("ArkTargetsPreview", 4)
public_result({ "manuscript" }, 3)
vim.api.nvim_set_current_win(source_win)

local preview = require("ark.targets_preview")
local ticks = 0
local timer = vim.uv.new_timer()
timer:start(
  0,
  10,
  vim.schedule_wrap(function()
    ticks = ticks + 1
  end)
)
local done, result, failure = false, nil, nil
local started = vim.uv.hrtime()
local handle = assert(preview.open(project, {
  names = { "manuscript" },
  on_complete = function(payload, err)
    result, failure, done = payload, err, true
  end,
}))
local dispatch_ms = (vim.uv.hrtime() - started) / 1e6
assert(dispatch_ms < 100, "preview blocked the editor: " .. dispatch_ms .. "ms")
assert(not done, "preview unexpectedly completed synchronously")
assert(
  vim.wait(15000, function()
    return done
  end, 10),
  "preview never completed"
)
timer:stop()
timer:close()
assert(not failure, failure)
assert(ticks >= 10, "Neovim did not service events while R evaluated the pipeline")
assert(result.outdated_total == 3 and result.target_total == 3, vim.inspect(result))
local rows = {}
for _, row in ipairs(result.targets) do
  rows[row.name] = row
end
assert(rows.raw.outdated and rows.clean.outdated and rows.manuscript.outdated, vim.inspect(rows))
assert(not rows.unrelated, "selection leaked unrelated pipeline targets")
assert(type(rows.raw.seconds) == "number" and rows.raw.seconds >= 0.01, "last recorded duration missing")
local lines = table.concat(vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false), "\n")
assert(lines:find("unsaved", 1, true), "preview failed to warn about unsaved source buffers")
assert(lines:find("raw -> clean", 1, true) and lines:find("clean -> manuscript", 1, true), lines)
assert(vim.fn.filereadable(root .. "/build-sentinel") == 0, "preview executed a target")
assert(vim.bo[source].modified, "preview unexpectedly saved the source buffer")
assert(vim.fn.readfile(project.script)[1] == slow_prefix, "preview modified the source file")

-- Payload bounds are explicit, with full counts retained rather than pretending
-- a truncated large pipeline has no other outdated targets.
done = false
preview.request(project, { max_targets = 1, max_edges = 1 }, function(payload, err)
  result, failure, done = payload, err, true
end)
assert(
  vim.wait(15000, function()
    return done
  end, 10),
  "bounded preview never completed"
)
assert(not failure, failure)
assert(#result.targets == 1 and result.target_total == 4 and result.targets_truncated, vim.inspect(result))
assert(#result.edges == 1 and result.edges_truncated, vim.inspect(result))

-- A real R process sleeping in configuration must be cancellable and bounded.
vim.fn.writefile(script("2", "Sys.sleep(30)"), project.script)
local first_done, second_done = false, false
local first = preview.open(project, {
  on_complete = function(_, err)
    assert(err:find("cancelled", 1, true), err)
    first_done = true
  end,
})
local second = preview.open(project, {
  on_complete = function(_, err)
    assert(err:find("cancelled", 1, true), err)
    second_done = true
  end,
})
assert(
  vim.wait(3000, function()
    return first_done
  end, 10),
  "superseded preview was not cancelled"
)
vim.api.nvim_buf_delete(second.bufnr, { force = true })
assert(
  vim.wait(3000, function()
    return second_done
  end, 10),
  "closing a preview did not cancel its worker"
)
vim.api.nvim_buf_delete(first.bufnr, { force = true })
done = false
local cancelled = preview.request(project, {}, function(_, err)
  failure, done = err, true
end)
vim.defer_fn(function()
  cancelled.cancel()
end, 100)
assert(
  vim.wait(3000, function()
    return done
  end, 10),
  "cancel did not stop the worker"
)
assert(failure:find("cancelled", 1, true), failure)
done = false
preview.request(project, { timeout_ms = 100 }, function(_, err)
  failure, done = err, true
end)
assert(
  vim.wait(3000, function()
    return done
  end, 10),
  "deadline did not stop the worker"
)
assert(failure:find("timed out", 1, true), failure)

-- Pipeline configuration can spawn descendants that inherit the worker's pipe.
-- Killing just R leaves that pipe open, so cancellation never reaches its
-- callback. Both cancellation and deadlines must terminate the private group.
local function process_state(pid)
  local readable, lines = pcall(vim.fn.readfile, "/proc/" .. pid .. "/stat")
  if not readable or not lines[1] then
    return nil
  end
  local state, _, group = lines[1]:match("^%d+ %b() (%S+) (%S+) (%S+)")
  return state, tonumber(group)
end
for _, mode in ipairs({ "cancelled", "timed out" }) do
  local child_file = root .. "/child-" .. mode:gsub(" ", "-") .. ".pid"
  local worker_file = root .. "/worker.pid"
  local shell = "sh -c " .. vim.fn.shellescape("sleep 30 & echo $! > " .. vim.fn.shellescape(child_file))
  local prefix = "writeLines(as.character(Sys.getpid()), "
    .. vim.json.encode(worker_file)
    .. "); system("
    .. vim.json.encode(shell)
    .. "); Sys.sleep(30)"
  vim.fn.writefile(script("2", prefix), project.script)
  done = false
  local child_handle = preview.request(project, { timeout_ms = mode == "timed out" and 3000 or 10000 }, function(_, err)
    failure, done = err, true
  end)
  assert(
    vim.wait(5000, function()
      return vim.fn.filereadable(child_file) == 1
    end, 10),
    "configuration child did not start"
  )
  local child = assert(tonumber(vim.fn.readfile(child_file)[1]))
  local worker = assert(tonumber(vim.fn.readfile(worker_file)[1]))
  local _, group = process_state(child)
  if mode == "cancelled" then
    child_handle.cancel()
  end
  local timely = vim.wait(mode == "cancelled" and 1500 or 4000, function()
    return done
  end, 10)
  local terminated = vim.wait(1000, function()
    local state = process_state(child)
    return state == nil or state == "Z"
  end, 10)
  -- Clean up even on a red run: do not leak the very descendant we diagnose.
  if not terminated then
    vim.uv.kill(child, 9)
  end
  if not timely then
    child_handle.cancel()
    vim.wait(1000, function()
      return done
    end, 10)
  end
  assert(group == worker, "preview descendants did not belong to a private worker process group")
  assert(timely, mode .. " preview waited for a descendant's inherited pipe")
  assert(terminated, mode .. " preview leaked its configuration subprocess")
  assert(failure:find(mode, 1, true), failure)
end

vim.fn.writefile({ "stop('preview fixture error')" }, project.script)
done = false
preview.request(project, {}, function(_, err)
  failure, done = err, true
end)
assert(
  vim.wait(5000, function()
    return done
  end, 10),
  "error callback missing"
)
assert(failure:find("preview fixture error", 1, true), failure)

-- User configuration can print. Drain it without buffering the entire stream,
-- and terminate a flood instead of scheduling unbounded output processing.
vim.fn.writefile(script("2", "cat(strrep('x', 131072))"), project.script)
done = false
local noisy = preview.request(project, {}, function(payload, err)
  result, failure, done = payload, err, true
end)
assert(
  vim.wait(10000, function()
    return done
  end, 10),
  "noisy preview stalled"
)
assert(not failure, failure)
assert(noisy.output_bytes > 131072 and noisy.retained_output_bytes <= 8192, vim.inspect(noisy))
vim.fn.writefile(script("2", "cat(strrep('x', 2000000)); Sys.sleep(30)"), project.script)
done = false
preview.request(project, {}, function(_, err)
  failure, done = err, true
end)
assert(
  vim.wait(5000, function()
    return done
  end, 10),
  "output bound did not stop the worker"
)
assert(failure:find("output limit", 1, true), failure)

vim.api.nvim_buf_delete(handle.bufnr, { force = true })
vim.print({
  targets_rebuild_preview = "ok",
  dispatch_ms = dispatch_ms,
  public_dispatch_ms = public_dispatch_ms,
  responsive_ticks = ticks,
})
stop_watchdog()
