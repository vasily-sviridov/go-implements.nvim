local M = {}
local api = vim.api
local ns = api.nvim_create_namespace('go-implements')
local options = { enabled = true, debounce_ms = 300, highlight = 'LspCodeLens' }
local sessions, attached = {}, {}
local modern = vim.fn.has('nvim-0.11') == 1
local refresh_session

-- 0.10 exposes bound closures; 0.11 introduced colon-style client methods.
local function call(client, method, ...)
  if modern then
    return client[method](client, ...)
  end
  return client[method](...)
end

local function clear(buf)
  if api.nvim_buf_is_valid(buf) then
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
end

local function stop(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function later(ms, fn)
  local timer = (vim.uv or vim.loop).new_timer()
  timer:start(ms, 0, vim.schedule_wrap(function()
    stop(timer)
    fn()
  end))
  return timer
end

-- All requests, including naming requests, share a bounded client-wide queue.
local function pump(s)
  while options.enabled and s.active < 4 and s.head <= #s.queue do
    local job = s.queue[s.head]
    s.head = s.head + 1
    if job.epoch == s.epoch then
      s.active = s.active + 1
      local finished = false
      local timer, id
      local function finish(err, result)
        if finished then return end
        finished = true
        stop(timer)
        s.pending[job] = nil
        s.active = s.active - 1
        vim.schedule(function()
          if job.epoch == s.epoch and options.enabled then
            job.done(err, result)
          end
          pump(s)
        end)
      end
      job.cancel = function()
        if id then pcall(call, s.client, 'cancel_request', id) end
        finish({ message = 'cancelled' })
      end
      s.pending[job] = true
      local ok, accepted, request_id = pcall(call, s.client, 'request', job.method, job.params, finish, job.buf)
      id = request_id
      if not ok or not accepted then
        finish({ message = 'request rejected' })
      elseif not finished then
        timer = later(15000, function()
          timer = nil
          job.cancel()
        end)
      end
    end
  end
  if s.head > #s.queue then s.queue, s.head = {}, 1 end
end

local function request(s, method, params, buf, done)
  s.queue[#s.queue + 1] = { epoch = s.epoch, method = method, params = params, buf = buf, done = done }
  pump(s)
end

local function invalidate(s)
  s.epoch = s.epoch + 1
  s.queue, s.head, s.names = {}, 1, {}
  local pending = {}
  for job in pairs(s.pending) do pending[#pending + 1] = job end
  for _, job in ipairs(pending) do job.cancel() end
  for buf, state in pairs(s.buffers) do
    state.ready = false
    clear(buf)
  end
  stop(s.timer)
  s.timer = nil
  if options.enabled and next(s.buffers) then
    local epoch = s.epoch
    s.timer = later(options.debounce_ms, function()
      if epoch ~= s.epoch then return end
      s.timer = nil
      refresh_session(s)
    end)
  end
end

local function location(loc)
  return loc.uri or loc.targetUri, loc.range or loc.targetSelectionRange or loc.targetRange
end

local function hover_text(result)
  local content = result and result.contents
  if type(content) == 'string' then return content end
  if type(content) ~= 'table' then return '' end
  if content.value then return content.value end
  local parts = {}
  for _, part in ipairs(content) do
    parts[#parts + 1] = type(part) == 'string' and part or part.value or ''
  end
  return table.concat(parts, '\n')
end

local function name_from_hover(result)
  local text = hover_text(result)
  local declared = ('\n' .. text):match('\n%s*type%s+([^%s%[%=]+)')
  -- gopls' documentation link carries the actual package name, not a path guess.
  -- Its footer comes after documentation, which may itself contain links.
  local qualified
  for name in text:gmatch('%[`([^`]+)`[^%]]*%]%([^\n]+%)') do
    if name:match('^[%w_\128-\255]+%.[%w_\128-\255]+$')
      and declared and (name == declared or name:match('%.([^%.]+)$') == declared) then
      qualified = name
    end
  end
  if qualified then return qualified end
  -- Plaintext / linksInHover=false / private symbols: retain the unqualified name.
  return declared
end

local function resolve_name(s, loc, buf, done)
  local uri, range = location(loc)
  if not uri or not range then done(nil); return end
  local key = uri .. ':' .. range.start.line .. ':' .. range.start.character
  local cached = s.names[key]
  if cached then
    if cached.name then done(cached.name) else cached.waiters[#cached.waiters + 1] = done end
    return
  end
  cached = { waiters = { done } }
  s.names[key] = cached
  request(s, 'textDocument/hover', { textDocument = { uri = uri }, position = range.start }, buf, function(err, result)
    local name = not err and name_from_hover(result)
    -- Never load target buffers or infer a package name from a directory.
    name = name or (vim.fn.fnamemodify(vim.uri_to_fname(uri), ':t') .. ':' .. (range.start.line + 1))
    cached.name = name
    local waiters = cached.waiters
    cached.waiters = nil
    for _, waiter in ipairs(waiters) do waiter(name) end
  end)
end

local function concrete(symbol)
  if not symbol.selectionRange or not symbol.range then return false end
  if symbol.kind == 23 then return true end -- Struct
  local detail = symbol.detail or ''
  if symbol.kind == 5 then -- gopls Class: syntactically unspecified type
    -- Builtin names can be shadowed by an interface. Thus even `int` is
    -- ambiguous without semantic classification; only explicit type literals
    -- are accepted here. Ambiguous symbols use gopls type hierarchy below.
    return detail:match('^%[') or detail:match('^map%[') or detail:match('^%*')
      or detail:match('^chan%s') or detail:match('^chan<%-') or detail:match('^<%-chan%s')
  end
  -- gopls gives function type specs and function declarations the same kind.
  -- Only a type spec's range starts at its name.
  return symbol.kind == 12 and symbol.range.start.line == symbol.selectionRange.start.line
    and symbol.range.start.character == symbol.selectionRange.start.character
end

local function render(buf, symbol, names)
  if #names == 0 then return end
  table.sort(names)
  api.nvim_buf_set_extmark(buf, ns, symbol.range.start.line, 0, {
    virt_lines = { { { 'implements ' .. table.concat(names, ', '), options.highlight } } },
    virt_lines_above = true,
    hl_mode = 'combine',
  })
end

local function query(s, buf, symbol)
  request(s, 'textDocument/implementation', {
    textDocument = { uri = vim.uri_from_bufnr(buf) }, position = symbol.selectionRange.start,
  }, buf, function(err, result)
    if err then s.buffers[buf].ready = false; return end
    if not result or #result == 0 then return end
    local unique, seen = {}, {}
    for _, loc in ipairs(result) do
      local uri, range = location(loc)
      if uri and range then
        local key = uri .. ':' .. range.start.line .. ':' .. range.start.character
        if not seen[key] then unique[#unique + 1], seen[key] = loc, true end
      end
    end
    local remaining, names = #unique, {}
    for _, loc in ipairs(unique) do
      resolve_name(s, loc, buf, function(name)
        if name then names[#names + 1] = { name = name, loc = loc } end
        remaining = remaining - 1
        if remaining == 0 then
          local counts, labels = {}, {}
          for _, item in ipairs(names) do counts[item.name] = (counts[item.name] or 0) + 1 end
          for _, item in ipairs(names) do
            local label = item.name
            if counts[label] > 1 then
              local uri, range = location(item.loc)
              label = label .. ' [' .. vim.uri_to_fname(uri) .. ':' .. (range.start.line + 1) .. ']'
            end
            labels[#labels + 1] = label
          end
          render(buf, symbol, labels)
        end
      end)
    end
  end)
end

refresh_session = function(s)
  for buf, state in pairs(s.buffers) do
    if api.nvim_buf_is_loaded(buf) and not state.ready then
      state.ready = true
      clear(buf)
      request(s, 'textDocument/documentSymbol', { textDocument = { uri = vim.uri_from_bufnr(buf) } }, buf, function(err, symbols)
        if err or not symbols then state.ready = false; return end
        -- gopls returns top-level DocumentSymbols. Do not walk fields/methods.
        for _, symbol in ipairs(symbols) do
          if concrete(symbol) then
            query(s, buf, symbol)
          elseif symbol.kind == 5 and symbol.selectionRange and s.client.server_capabilities.typeHierarchyProvider then
            request(s, 'textDocument/prepareTypeHierarchy', {
              textDocument = { uri = vim.uri_from_bufnr(buf) }, position = symbol.selectionRange.start,
            }, buf, function(classify_err, items)
              if classify_err or not items or #items == 0 then state.ready = false; return end
              if items and #items == 1 and items[1].kind == 5 then query(s, buf, symbol) end
            end)
          end
        end
      end)
    end
  end
end

local function attach(buf)
  if not options.enabled or not api.nvim_buf_is_loaded(buf) or vim.bo[buf].filetype ~= 'go' then return end
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf, name = 'gopls' })) do
    local s = sessions[client.id]
    if not s then
      s = { client = client, epoch = 0, buffers = {}, queue = {}, head = 1, pending = {}, names = {}, active = 0 }
      sessions[client.id] = s
    end
    if not s.buffers[buf] then
      s.buffers[buf] = { ready = false }
      invalidate(s)
    elseif not s.buffers[buf].ready and not s.timer then
      invalidate(s)
    end
    if not attached[buf] then
      attached[buf] = true
      api.nvim_buf_attach(buf, false, {
        on_lines = function()
          for _, session in pairs(sessions) do
            if session.buffers[buf] then invalidate(session) end
          end
        end,
        on_detach = function()
          attached[buf] = nil
          for _, session in pairs(sessions) do
            if session.buffers[buf] then session.buffers[buf] = nil; invalidate(session) end
          end
        end,
        on_reload = function()
          for _, session in pairs(sessions) do
            if session.buffers[buf] then invalidate(session) end
          end
        end,
      })
    end
    return -- Exactly one gopls owns this buffer's annotations.
  end
end

function M.refresh(buf)
  buf = buf or api.nvim_get_current_buf()
  if buf == 0 then buf = api.nvim_get_current_buf() end
  attach(buf)
  for _, s in pairs(sessions) do
    if s.buffers[buf] then invalidate(s) end
  end
end

function M.setup(opts)
  options = vim.tbl_extend('force', { enabled = true, debounce_ms = 300, highlight = 'LspCodeLens' }, opts or {})
  assert(type(options.enabled) == 'boolean', 'enabled must be a boolean')
  assert(type(options.highlight) == 'string' and options.highlight ~= '', 'highlight must be a nonempty string')
  assert(type(options.debounce_ms) == 'number' and options.debounce_ms >= 0 and options.debounce_ms < math.huge,
    'debounce_ms must be finite and nonnegative')
  for _, s in pairs(sessions) do invalidate(s); stop(s.timer) end
  sessions = {}
  local group = api.nvim_create_augroup('GoImplements', { clear = true })
  api.nvim_create_user_command('GoImplementsRefresh', function() M.refresh() end, { desc = 'Refresh Go interface annotations', force = true })
  api.nvim_create_autocmd({ 'LspAttach', 'BufEnter' }, { group = group, callback = function(args) attach(args.buf) end })
  api.nvim_create_autocmd('LspDetach', { group = group, callback = function(args)
    local s = sessions[args.data.client_id]
    if s and s.buffers[args.buf] then
      s.buffers[args.buf] = nil
      clear(args.buf)
      invalidate(s)
      if not next(s.buffers) then sessions[args.data.client_id] = nil end
    end
  end })
  api.nvim_create_autocmd('LspNotify', { group = group, callback = function(args)
    local s = sessions[args.data.client_id]
    local method = args.data.method
    if not s then return end
    if method == 'textDocument/didChange' then
      local uri = args.data.params and args.data.params.textDocument and args.data.params.textDocument.uri
      -- on_lines already invalidated tracked Go buffers synchronously. Other
      -- documents (notably go.mod/go.work) can change this client's semantics.
      for buf in pairs(s.buffers) do
        if api.nvim_buf_is_valid(buf) and vim.uri_from_bufnr(buf) == uri then return end
      end
      invalidate(s)
    elseif method == 'workspace/didChangeWatchedFiles' or method == 'workspace/didChangeConfiguration'
      or method == 'workspace/didChangeWorkspaceFolders' or method == 'textDocument/didSave'
      or method == 'textDocument/didOpen' or method == 'textDocument/didClose' then invalidate(s) end
  end })
  api.nvim_create_autocmd('LspProgress', { group = group, callback = function(args)
    local s = sessions[args.data.client_id]
    local value = args.data.params and args.data.params.value
    if s and type(value) == 'table' and (value.kind == 'begin' or value.kind == 'end') then invalidate(s) end
  end })
  if not M._handler_installed then
    M._handler_installed = true
    local original = vim.lsp.handlers['workspace/codeLens/refresh']
    vim.lsp.handlers['workspace/codeLens/refresh'] = function(err, result, ctx, config)
      local s = sessions[ctx.client_id]
      if s then invalidate(s) end
      if original then return original(err, result, ctx, config) end
      return vim.NIL
    end
  end
  if options.enabled then
    for _, buf in ipairs(api.nvim_list_bufs()) do attach(buf) end
  end
end

return M
