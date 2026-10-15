-- Value responses are bounded. Small columns keep the normal fuzzy select UI;
-- large columns search the complete server-side index, never a truncated list.
local M = {}

local function label(item)
  return string.format("%s (%d)", item.label or "", tonumber(item.count or 0) or 0)
end

function M.open(opts, payload)
  local items = payload.values or {}
  local ok, snacks = pcall(require, "snacks")
  local has_picker = ok and type(snacks.picker) == "table" and type(snacks.picker.pick) == "function"
  local function retain_origin(picker)
    if opts.origin_win and vim.api.nvim_win_is_valid(opts.origin_win) then
      picker.main = opts.origin_win
    end
  end
  if tonumber(payload.total_values or #items) <= #items then
    if has_picker and type(snacks.picker.select) == "function" then
      return snacks.picker.select(items, {
        prompt = opts.title,
        format_item = label,
        snacks = {
          main = { current = true },
          on_show = retain_origin,
          transform = function(item)
            item.text = item.item.label or ""
          end,
        },
      }, opts.choose)
    end
    if has_picker then
      return snacks.picker.pick({
        title = opts.title,
        main = { current = true },
        on_show = retain_origin,
        items = vim.tbl_map(function(item)
          return { text = item.label or "", item = item }
        end, items),
        format = function(item)
          return { { label(item.item) } }
        end,
        confirm = function(picker, item)
          picker:close()
          if item then
            opts.choose(item.item)
          end
        end,
      })
    end
    return vim.ui.select(items, { prompt = opts.title, format_item = label }, opts.choose)
  end

  if not has_picker then
    vim.ui.input({ prompt = opts.title .. " — search values (up to 1000 matches): " }, function(query)
      if query == nil then
        return
      end
      opts.fetch(query, function(result, err)
        if err then
          opts.notify(err)
          return
        end
        if not result then
          return
        end
        if tonumber(result.matched_values or 0) > #(result.values or {}) then
          opts.notify("Showing the first 1000 matches; narrow the search to find other values")
        end
        vim.ui.select(result.values or {}, { prompt = opts.title, format_item = label }, opts.choose)
      end)
    end)
    return
  end

  return snacks.picker.pick({
    title = string.format("%s — search %d values (up to 1000 matches)", opts.title, payload.total_values),
    main = { current = true },
    on_show = retain_origin,
    live = true,
    supports_live = true,
    -- Live input is a literal, case-insensitive server-side search, not a fuzzy
    -- match against the first page. Metadata (row index/count) is never searched.
    finder = function(_, ctx)
      if ctx.filter.search == "" then
        return vim.tbl_map(function(item)
          return { text = item.label or "", item = item }
        end, items)
      end
      return function(add)
        ctx.async:sleep(120) -- debounce typing, without polling R
        local response, failure, complete
        local cancel
        ctx.async:on("abort", function()
          if cancel then
            cancel()
          end
        end)
        ctx.async:schedule(function()
          local _, _, stop = opts.fetch(ctx.filter.search, function(result, err)
            response, failure, complete = result, err, true
            if ctx.async:running() then
              ctx.async:resume()
            end
          end)
          cancel = stop
        end)
        if not complete then
          ctx.async:suspend()
        end
        if failure then
          ctx.async:schedule(function()
            opts.notify(failure)
          end)
          return
        end
        for _, item in ipairs(response and response.values or {}) do
          add({ text = item.label or "", item = item })
        end
      end
    end,
    format = function(item)
      return { { label(item.item) } }
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        vim.schedule(function()
          opts.choose(item.item)
        end)
      end
    end,
  })
end

return M
