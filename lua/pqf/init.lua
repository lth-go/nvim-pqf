local api = vim.api
local fn = vim.fn

local M = {}

local signs = {
  error = { text = 'E', hl = 'DiagnosticSignError' },
  warning = { text = 'W', hl = 'DiagnosticSignWarn' },
  info = { text = 'I', hl = 'DiagnosticSignInfo' },
  hint = { text = 'H', hl = 'DiagnosticSignHint' },
}

local type_mapping = {
  E = signs.error,
  W = signs.warning,
  I = signs.info,
  N = signs.hint,
}

local namespace = api.nvim_create_namespace('pqf')
local max_filename_length = 0
local filename_truncate_prefix = '[...]'
local path_display = nil

local function pad_left(s, pad_to)
  if pad_to == 0 then
    return s
  end

  local width = fn.strwidth(s)

  if width >= pad_to then
    return s
  end

  return string.rep(' ', pad_to - width) .. s
end

local function pad_right(s, pad_to)
  if pad_to == 0 then
    return s
  end

  local width = fn.strwidth(s)

  if width >= pad_to then
    return s
  end

  return s .. string.rep(' ', pad_to - width)
end

local function trim_path(path)
  local fname = fn.fnamemodify(path, ':p:.')

  if path_display then
    fname = path_display(fname)
  end

  local len = fn.strchars(fname)

  if max_filename_length > 0 and len > max_filename_length then
    fname = filename_truncate_prefix
      .. fn.strpart(fname, len - max_filename_length, max_filename_length, 1)
  end

  return fname
end

local function list_items(info)
  if info.quickfix == 1 then
    return fn.getqflist({ id = info.id, items = 1, qfbufnr = 1 })
  end

  return fn.getloclist(info.winid, { id = info.id, items = 1, qfbufnr = 1 })
end

local function apply_highlights(bufnr, highlights)
  for _, hl in ipairs(highlights) do
    vim.highlight.range(
      bufnr,
      namespace,
      hl.group,
      { hl.line, hl.col },
      { hl.line, hl.end_col }
    )
  end
end

function M.format(info)
  local list = list_items(info)
  local qf_bufnr = list.qfbufnr
  local raw_items = list.items

  local items = {}
  local show_sign = false
  local pad_to = 0
  local num_pad_to = 0

  -- If we're adding a new list rather than appending to an existing one, we
  -- need to clear existing highlights.
  if info.start_idx == 1 then
    api.nvim_buf_clear_namespace(qf_bufnr, namespace, 0, -1)
  end

  for i = info.start_idx, info.end_idx do
    local raw = raw_items[i]

    if raw then
      local item = {
        index = i,
        sign = ' ',
        sign_hl = nil,
        location = '',
        location_size = 0,
        lnum = '',
        lnum_size = 0,
        text = raw.text,
      }

      --
      --
      --

      local sign_conf = type_mapping[raw.type]
      if sign_conf then
        item.sign = sign_conf.text
        item.sign_hl = sign_conf.hl

        show_sign = true
      end

      --
      --
      --

      if raw.bufnr > 0 then
        item.location = trim_path(fn.bufname(raw.bufnr))
        item.location_size = fn.strwidth(item.location)

        if item.location_size > pad_to then
          pad_to = item.location_size
        end
      end

      --
      --
      --

      if raw.lnum and raw.lnum > 0 then
        local lnum = tostring(raw.lnum)

        if raw.end_lnum and raw.end_lnum > 0 and raw.end_lnum ~= raw.lnum then
          lnum = lnum .. '-' .. raw.end_lnum
        end

        item.lnum = lnum
        item.lnum_size = fn.strwidth(item.lnum)

        if item.lnum_size > num_pad_to then
          num_pad_to = item.lnum_size
        end
      end

      --
      --
      --

      -- Quickfix items only support singe-line messages, and show newlines as
      -- funny characters. In addition, many language servers (e.g.
      -- rust-analyzer) produce super noisy multi-line messages where only the
      -- first line is relevant.
      --
      -- To handle this, we only include the first line of the message in the
      -- quickfix line.
      local text = vim.split(raw.text, '\n')[1]
      item.text = fn.trim(text)

      table.insert(items, item)
    end
  end

  local lines = {}
  local highlights = {}

  for _, item in ipairs(items) do
    local line = ''
    local line_idx = item.index - 1

    --
    --
    --

    if show_sign and item.sign_hl then
      line = line .. item.sign

      table.insert(highlights, {
        group = item.sign_hl,
        line = line_idx,
        col = 0,
        end_col = #item.sign,
      })
    end

    --
    --
    --

    if item.location_size > 0 then
      if line ~= '' then
        line = line .. ' '
      end

      local col = fn.strwidth(line)
      line = line .. pad_right(item.location, pad_to)

      table.insert(highlights, {
        group = 'Directory',
        line = line_idx,
        col = col,
        end_col = col + item.location_size,
      })
    end

    --
    --
    --

    if item.lnum_size > 0 then
      if line ~= '' then
        line = line .. ' '
      end

      local col = fn.strwidth(line)
      line = line .. '|' .. pad_left(item.lnum, num_pad_to) .. '|'

      table.insert(highlights, {
        group = 'LineNr',
        line = line_idx,
        col = col,
        end_col = col + num_pad_to + 2,
      })
    end

    --
    --
    --

    if item.text ~= '' then
      if line ~= '' then
        line = line .. ' '
      end

      line = line .. item.text
    end

    -- If a line is completely empty, Vim uses the default format, which
    -- involves inserting `|| `. To prevent this from happening we'll just
    -- insert an empty space instead.
    if line == '' then
      line = ' '
    end

    table.insert(lines, line)
  end

  -- Applying highlights has to be deferred, otherwise they won't apply to the
  -- lines inserted into the quickfix window.
  vim.schedule(function()
    apply_highlights(qf_bufnr, highlights)
  end)

  return lines
end

function M.setup(opts)
  opts = opts or {}

  if opts.signs then
    assert(type(opts.signs) == 'table', 'the "signs" option must be a table')
    signs = vim.tbl_deep_extend('force', signs, opts.signs)
  end

  if opts.max_filename_length then
    max_filename_length = opts.max_filename_length
    assert(
      type(max_filename_length) == 'number',
      'the "max_filename_length" option must be a number'
    )
  end

  if opts.filename_truncate_prefix then
    filename_truncate_prefix = opts.filename_truncate_prefix
    assert(
      type(filename_truncate_prefix) == 'string',
      'the "filename_truncate_prefix" option must be a string'
    )
  end

  if opts.path_display then
    path_display = opts.path_display
    assert(
      type(path_display) == 'function',
      'the "path_display" option must be a function'
    )
  end

  vim.o.quickfixtextfunc = "v:lua.require'pqf'.format"
end

return M
