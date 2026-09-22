vim.opt.runtimepath:prepend(vim.fn.getcwd())
local api = vim.api
local delegated = 0
vim.lsp.handlers['workspace/codeLens/refresh'] = function()
  delegated = delegated + 1
  return vim.NIL
end
-- Exercise the 0.10 bound-closure branch on newer Neovim as well.
local legacy = vim.env.GO_IMPLEMENTS_TEST_LEGACY == '1' or vim.fn.has('nvim-0.11') == 0
if legacy then
  local has = vim.fn.has
  vim.fn.has = function(feature) return feature == 'nvim-0.11' and 0 or has(feature) end
end
local plugin = require('go-implements')
local ns = api.nvim_create_namespace('go-implements')
local original_clients = vim.lsp.get_clients
local tests, passed = {}, 0
local client, pending, counts, buffers, responder, live, maximum

local function eq(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect(actual) .. ' ~= ' .. vim.inspect(expected))
end
local function wait(predicate)
  assert(vim.wait(3000, predicate, 5), 'timed out')
end
local function range(line, col)
  return { start = { line = line, character = col or 5 }, ['end'] = { line = line, character = (col or 5) + 3 } }
end
local function symbol(name, line, kind, detail)
  return { name = name, kind = kind or 23, detail = detail or 'struct{}', range = range(line), selectionRange = range(line) }
end
local function loc(line, uri)
  return { uri = uri or 'file:///external/io.go', range = range(line or 0) }
end
local function hover(name)
  return { contents = { kind = 'markdown', value = '```go\ntype ' .. name:match('[^.]+$') .. ' interface {}\n```\n\n[`' .. name .. '` on pkg.go.dev](https://pkg.go.dev/io#Reader)' } }
end
local function marks(buf)
  local texts = {}
  for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    assert(mark[4].virt_lines_above)
    texts[#texts + 1] = mark[4].virt_lines[1][1][1]
  end
  return texts
end
local function buffer(lines)
  local buf = api.nvim_create_buf(true, false)
  api.nvim_buf_set_name(buf, '/tmp/go-implements-test-' .. buf .. '.go')
  api.nvim_buf_set_lines(buf, 0, -1, false, lines or { 'package test', 'type Foo struct{}', 'type Bar struct{}', 'type Baz struct{}' })
  vim.bo[buf].filetype = 'go'
  buffers[#buffers + 1] = buf
  return buf
end
local function reset()
  plugin.setup({ enabled = false })
  for _, buf in ipairs(buffers or {}) do pcall(api.nvim_buf_delete, buf, { force = true }) end
  pending, counts, buffers, live, maximum = {}, {}, {}, 0, 0
  client = { id = 9001, name = 'gopls', server_capabilities = { typeHierarchyProvider = true } }
  function client:request(method, params, callback, buf)
    counts[method] = (counts[method] or 0) + 1
    live = live + 1
    maximum = math.max(maximum, live)
    local item = { method = method, params = params, buf = buf }
    function item.reply(err, result)
      if not item.replied then live = live - 1; item.replied = true end
      callback(err, result)
    end
    pending[#pending + 1] = item
    if responder then
      local err, result, hold = responder(method, params, buf)
      if not hold then vim.schedule(function() item.reply(err, result) end) end
    end
    return true, #pending
  end
  function client:cancel_request(id) pending[id].cancelled = true end
  if legacy then
    local request, cancel = client.request, client.cancel_request
    client.request = function(...) return request(client, ...) end
    client.cancel_request = function(...) return cancel(client, ...) end
  end
  vim.lsp.get_clients = function() return client and { client } or {} end
end
local function start()
  plugin.setup({ debounce_ms = 5 })
end
local function idle()
  wait(function() return live == 0 end)
  vim.wait(40, function() return false end, 5)
end
local function test(name, fn) tests[#tests + 1] = { name, fn } end

test('one interface; external buffer remains unloaded; unchanged buffer cached', function()
  responder = function(method)
    if method == 'textDocument/documentSymbol' then return nil, { symbol('Foo', 1) } end
    if method == 'textDocument/implementation' then return nil, { loc() } end
    return nil, hover('io.Reader')
  end
  local buf = buffer()
  local before = #api.nvim_list_bufs()
  start()
  wait(function() return #marks(buf) == 1 end)
  eq(marks(buf), { 'implements io.Reader' })
  eq(#api.nvim_list_bufs(), before)
  api.nvim_exec_autocmds('BufEnter', { buffer = buf })
  idle()
  eq(counts['textDocument/implementation'], 1)
end)

test('multiple interfaces sorted and duplicate locations coalesced', function()
  responder = function(method, params)
    if method == 'textDocument/documentSymbol' then return nil, { symbol('Foo', 1) } end
    if method == 'textDocument/implementation' then return nil, { loc(0), loc(1), loc(0) } end
    return nil, hover(params.position.line == 0 and 'io.Reader' or 'io.Closer')
  end
  local buf = buffer(); start()
  wait(function() return #marks(buf) == 1 end)
  eq(marks(buf), { 'implements io.Closer, io.Reader' })
  eq(counts['textDocument/hover'], 2)
end)

test('no interfaces and interface declarations produce no annotation', function()
  responder = function(method)
    if method == 'textDocument/documentSymbol' then return nil, { symbol('Foo', 1), symbol('Reader', 2, 11) } end
    return nil, {}
  end
  local buf = buffer(); start()
  wait(function() return counts['textDocument/implementation'] == 1 end); idle()
  eq(marks(buf), {})
end)

test('multiple declarations and semantic classification of named types and aliases', function()
  responder = function(method, params)
    if method == 'textDocument/documentSymbol' then
      return nil, { symbol('Foo', 1), symbol('Bar', 2, 5, 'int'), symbol('Alias', 3, 5, 'OtherInterface') }
    end
    if method == 'textDocument/prepareTypeHierarchy' then return nil, { { kind = params.position.line == 2 and 5 or 11 } } end
    if method == 'textDocument/implementation' then return nil, { loc() } end
    return nil, hover('other.Interface')
  end
  local buf = buffer(); start()
  wait(function() return #marks(buf) == 2 end)
  eq(counts['textDocument/implementation'], 2)
  eq(counts['textDocument/hover'], 1)
end)

test('editing method sets invalidates all buffers immediately and debounces', function()
  local changed = false
  responder = function(method)
    if method == 'textDocument/documentSymbol' then return nil, { symbol('Foo', 1) } end
    if method == 'textDocument/implementation' then return nil, changed and {} or { loc() } end
    return nil, hover('io.Reader')
  end
  local buf, other = buffer(), buffer(); start()
  wait(function() return #marks(buf) == 1 and #marks(other) == 1 end)
  changed = true
  for i = 1, 20 do api.nvim_buf_set_lines(other, 3, 4, false, { '// method edit ' .. i }) end
  eq(marks(buf), {}); eq(marks(other), {})
  wait(function() return counts['textDocument/implementation'] == 4 end); idle()
  eq(marks(buf), {}); eq(counts['textDocument/documentSymbol'], 4)
end)

test('no gopls is a quiet no-op', function()
  client = nil; responder = nil
  local buf = buffer(); start(); plugin.refresh(buf); idle()
  eq(counts, {}); eq(marks(buf), {})
end)

test('stale replies cannot resurrect annotations', function()
  local hold = true
  responder = function(method)
    if method == 'textDocument/documentSymbol' then return nil, { symbol('Foo', 1) } end
    if method == 'textDocument/implementation' then return nil, {}, hold end
    return nil, hover('io.Reader')
  end
  local buf = buffer(); start()
  wait(function() return counts['textDocument/implementation'] == 1 end)
  local stale = pending[#pending]
  hold = false
  api.nvim_buf_set_lines(buf, 3, 4, false, { '// changed' })
  assert(stale.cancelled)
  stale.reply(nil, { loc() })
  wait(function() return counts['textDocument/implementation'] == 2 end); idle()
  eq(marks(buf), {}); eq(counts['textDocument/hover'], nil)
end)

test('many declarations have at most four requests in flight and one symbol scan', function()
  local symbols, lines = {}, { 'package test' }
  for i = 1, 200 do
    symbols[#symbols + 1] = symbol('T' .. i, i)
    lines[#lines + 1] = 'type T' .. i .. ' struct{}'
  end
  for _ = 1, 10000 do lines[#lines + 1] = '// ordinary line' end
  responder = function(method)
    if method == 'textDocument/documentSymbol' then return nil, symbols end
    if method == 'textDocument/implementation' then return nil, { loc() } end
    return nil, hover('pkg.Interface')
  end
  local buf = buffer(lines); start()
  wait(function() return #marks(buf) == 200 end)
  assert(maximum <= 4, maximum)
  eq(counts['textDocument/documentSymbol'], 1)
  eq(counts['textDocument/implementation'], 200)
  eq(counts['textDocument/hover'], 1)
end)

test('LocationLink and plaintext hover fallback', function()
  responder = function(method)
    if method == 'textDocument/documentSymbol' then return nil, { symbol('Foo', 1) } end
    if method == 'textDocument/implementation' then return nil, { { targetUri = 'file:///vendor/api.go', targetSelectionRange = range(2) } } end
    return nil, { contents = { kind = 'plaintext', value = 'type Private interface{}' } }
  end
  local buf = buffer(); start(); wait(function() return #marks(buf) == 1 end)
  eq(marks(buf), { 'implements Private' })
end)

test('failed hover has an honest location fallback', function()
  responder = function(method)
    if method == 'textDocument/documentSymbol' then return nil, { symbol('Foo', 1) } end
    if method == 'textDocument/implementation' then return nil, { loc(8) } end
    return { message = 'indexing' }
  end
  local buf = buffer(); start(); wait(function() return #marks(buf) == 1 end)
  eq(marks(buf), { 'implements io.go:9' })
end)

test('semantic progress clears marks and repopulates', function()
  responder = function(method)
    if method == 'textDocument/documentSymbol' then return nil, { symbol('Foo', 1) } end
    if method == 'textDocument/implementation' then return nil, { loc() } end
    return nil, hover('io.Reader')
  end
  local buf = buffer(); start(); wait(function() return #marks(buf) == 1 end)
  -- LspProgress is a standard server notification delivered by Neovim.
  api.nvim_exec_autocmds('LspProgress', { data = { client_id = 9001, params = { value = { kind = 'end' } } } })
  eq(marks(buf), {})
  wait(function() return #marks(buf) == 1 end)
  eq(counts['textDocument/implementation'], 2)
  local before = delegated
  eq(vim.lsp.handlers['workspace/codeLens/refresh'](nil, nil, { client_id = 9001 }), vim.NIL)
  eq(delegated, before + 1)
  eq(marks(buf), {})
  wait(function() return #marks(buf) == 1 end)
  eq(counts['textDocument/implementation'], 3)
end)

test('failed implementation retries on entry without duplicating successful marks', function()
  local fail = true
  responder = function(method)
    if method == 'textDocument/documentSymbol' then return nil, { symbol('Foo', 1) } end
    if method == 'textDocument/implementation' then
      if fail then return { message = 'indexing' } end
      return nil, { loc() }
    end
    return nil, hover('io.Reader')
  end
  local buf = buffer(); start()
  wait(function() return counts['textDocument/implementation'] == 1 end); idle()
  fail = false
  api.nvim_exec_autocmds('BufEnter', { buffer = buf })
  wait(function() return #marks(buf) == 1 end)
  eq(counts['textDocument/implementation'], 2)
end)

test('detach clears annotations and rejects a pending response', function()
  responder = function(method)
    if method == 'textDocument/documentSymbol' then return nil, { symbol('Foo', 1) } end
    return nil, nil, true
  end
  local buf = buffer(); start()
  wait(function() return counts['textDocument/implementation'] == 1 end)
  local stale = pending[#pending]
  api.nvim_exec_autocmds('LspDetach', { buffer = buf, data = { client_id = 9001 } })
  stale.reply(nil, { loc() }); idle()
  eq(marks(buf), {}); eq(counts['textDocument/hover'], nil)
end)

test('document symbol positions are forwarded without byte conversion', function()
  local unicode = symbol('名字', 1)
  unicode.selectionRange = range(1, 13)
  responder = function(method, params)
    if method == 'textDocument/documentSymbol' then return nil, { unicode } end
    if method == 'textDocument/implementation' then eq(params.position, { line = 1, character = 13 }) end
    return nil, {}
  end
  buffer(); start(); wait(function() return counts['textDocument/implementation'] == 1 end); idle()
end)

test('identical interface labels at different locations are not collapsed', function()
  responder = function(method)
    if method == 'textDocument/documentSymbol' then return nil, { symbol('Foo', 1) } end
    if method == 'textDocument/implementation' then return nil, { loc(0, 'file:///a/api.go'), loc(0, 'file:///b/api.go') } end
    return nil, hover('api.Reader')
  end
  local buf = buffer(); start(); wait(function() return #marks(buf) == 1 end)
  eq(marks(buf), { 'implements api.Reader [/a/api.go:1], api.Reader [/b/api.go:1]' })
end)

test('function declarations and fields are never queried', function()
  local fn = symbol('Run', 2, 12, 'func()')
  fn.range.start.character = 0
  local struct = symbol('Foo', 1)
  struct.children = { symbol('Nested', 1) }
  responder = function(method)
    if method == 'textDocument/documentSymbol' then return nil, { struct, fn } end
    return nil, {}
  end
  buffer(); start(); wait(function() return counts['textDocument/implementation'] == 1 end); idle()
  eq(counts['textDocument/implementation'], 1)
end)

test('manual refresh and setup disable clear state', function()
  responder = function(method)
    if method == 'textDocument/documentSymbol' then return nil, { symbol('Foo', 1) } end
    if method == 'textDocument/implementation' then return nil, { loc() } end
    return nil, hover('io.Reader')
  end
  local buf = buffer(); start(); wait(function() return #marks(buf) == 1 end)
  api.nvim_set_current_buf(buf)
  vim.cmd.GoImplementsRefresh()
  eq(marks(buf), {}); wait(function() return #marks(buf) == 1 end)
  plugin.setup({ enabled = false }); eq(marks(buf), {}); idle()
  eq(counts['textDocument/implementation'], 2)
end)

test('older gopls skips ambiguous names but supports slices and function types', function()
  client.server_capabilities.typeHierarchyProvider = nil
  responder = function(method)
    if method == 'textDocument/documentSymbol' then
      return nil, { symbol('Foo', 1, 5, '[]string'), symbol('Fn', 2, 12, 'func()'), symbol('Maybe', 3, 5, 'Other') }
    end
    return nil, {}
  end
  buffer(); start(); wait(function() return counts['textDocument/implementation'] == 2 end); idle()
  eq(counts['textDocument/prepareTypeHierarchy'], nil)
end)

local ok, err = xpcall(function()
  for _, entry in ipairs(tests) do
    responder = nil
    reset()
    entry[2]()
    passed = passed + 1
    print('PASS ' .. entry[1])
  end
end, debug.traceback)
plugin.setup({ enabled = false })
vim.lsp.get_clients = original_clients
if not ok then print(err); vim.cmd('cquit 1') end
print(string.format('%d tests passed', passed))
vim.cmd('qa!')
