-- GOPLS=/path/to/gopls nvim --headless -u NONE -l tests/integration.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.getcwd() .. '/tests/fixtures'
local ns = api.nvim_create_namespace('go-implements')
local plugin = require('go-implements')
vim.cmd.edit(root .. '/main.go')
vim.bo.filetype = 'go'
local buf = api.nvim_get_current_buf()
plugin.setup({ debounce_ms = 30 })
local id = vim.lsp.start({
  name = 'gopls', cmd = { vim.env.GOPLS or 'gopls' }, root_dir = root,
  cmd_env = { GOMAXPROCS = '2', GOTELEMETRY = 'off', GOCACHE = '/tmp/go-implements-live-cache', XDG_CACHE_HOME = '/tmp/go-implements-cache' },
})
assert(id, 'could not start gopls')
local function annotations()
  local result = {}
  for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local line = api.nvim_buf_get_lines(buf, mark[2], mark[2] + 1, false)[1]
    result[line] = mark[4].virt_lines[1][1][1]
  end
  return result
end
local function ready()
  local lenses = annotations()
  return lenses['type File struct{}'] and lenses['\tCount int'] and lenses['\tNames []string'] and lenses['\tOther Count']
end
local ok, err = xpcall(function()
  assert(vim.wait(60000, ready, 50), 'timed out: ' .. vim.inspect(annotations()))
  local lenses = annotations()
  print(vim.inspect(lenses))
  assert(lenses['type File struct{}']:find('io.Reader', 1, true))
  assert(lenses['type File struct{}']:find('io.Closer', 1, true))
  assert(lenses['\tCount int']:find('contracts.Runner', 1, true))
  assert(lenses['\tCount int']:find('fixture.Local', 1, true))
  assert(vim.tbl_count(lenses) == 4, 'unexpected lens on interface or empty type')
  -- A method edit, without changing the type declaration, removes its lens.
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do
    if line == 'func (Count) Run() {}' then
      api.nvim_buf_set_lines(buf, i - 1, i, false, { 'func (Count) Stop() {}' })
      break
    end
  end
  assert(next(annotations()) == nil, 'edit did not clear annotations immediately')
  assert(vim.wait(30000, function()
    local current = annotations()
    return current['type File struct{}'] and current['\tNames []string'] and current['\tOther Count']
  end, 50), 'refresh timed out')
  assert(annotations()['\tCount int'] == nil, 'stale method-set result')
  print('PASS live gopls: standard library, external package, named concrete types, aliases, pointer methods, editing')
end, debug.traceback)
plugin.setup({ enabled = false })
local client = vim.lsp.get_client_by_id(id)
if client then
  if vim.fn.has('nvim-0.11') == 1 then client:stop(true) else client.stop(true) end
end
if not ok then print(err); vim.cmd('cquit 1') end
vim.cmd('qa!')
