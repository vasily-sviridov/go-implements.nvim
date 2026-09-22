# go-implements.nvim

Persistent Go interface annotations above named concrete type declarations:

```text
implements io.Closer, io.ReadCloser, io.Reader
type File struct {
```

Requires Neovim **0.10+** and an attached LSP client named **gopls**. No Lua
dependencies, Tree-sitter parser, lspconfig, or separate Go program are required.
This plugin does not start or configure gopls.

## Setup

Install this repository with your plugin manager, or put it on Neovim's
`runtimepath`, then call:

```lua
require('go-implements').setup({
  enabled = true,
  debounce_ms = 300,
  highlight = 'LspCodeLens',
})
```

All options are optional. Calling `setup` again replaces the configuration;
`enabled = false` clears annotations and cancels outstanding work. Setup handles
both existing gopls attachments and future `LspAttach` events.

Use `:GoImplementsRefresh` to invalidate and refresh the current buffer's gopls
session. There is no automatic plugin entrypoint: calling `setup` is sufficient.

## How it works

1. An asynchronous `textDocument/documentSymbol` request discovers top-level
   declarations. The plugin uses gopls' symbol kinds and ranges, including grouped
   declarations. It does not scan source lines or inspect method signatures.
2. Structs and explicit concrete type literals (slices, arrays, maps, channels,
   pointers, function types) are eligible. For ambiguous named types such as
   `type Count int`, `type Other Count`, and aliases, the plugin uses
   `textDocument/prepareTypeHierarchy`, when advertised, to ask gopls whether the
   type is concrete. This matters even for `int`, which Go permits shadowing with
   an interface. Interface declarations and aliases to interfaces are skipped.
3. Each eligible type receives one raw asynchronous
   `textDocument/implementation` request at its LSP `selectionRange.start`.
   Returned locations are authoritative. No interface matching or type checking
   happens in Lua. Positions remain in the server's negotiated encoding.
4. An asynchronous hover at each distinct target location supplies its display
   name. gopls' documentation link includes its actual package name, such as
   `io.Reader` or `contracts.Runner`, even when the directory has another name.
   This also works for same-package and vendored interfaces when gopls provides
   the link. Aliases are displayed only as exposed by gopls.
5. Native extmarks use `virt_lines_above = true` and the configured highlight.
   The Go buffer text is never modified. For grouped declarations the annotation
   appears above the individual type spec. Interface names are sorted, duplicate
   locations are collapsed, and distinct locations with identical display names
   get a path-and-line suffix so neither interface disappears.

These are virtual lines, rather than actual LSP CodeLens objects: the CodeLens
protocol has no placement control, and Neovim's CodeLens display does not provide
the required above-declaration placement. No mouse bindings or jump commands are
installed; normal Neovim implementation navigation remains available.

## Performance and refresh

There are at most **four active requests per gopls client**, shared across symbol
discovery, classification, implementation queries, and naming. A large file costs
one symbol request plus one implementation request per eligible declaration,
plus classification for ambiguous declarations and one hover per unique target.
Requests time out after 15 seconds and release their queue slot.

Successful results, including empty results, remain cached for the current
semantic generation. Entering an unchanged buffer does not requery it. Concurrent
requests for the same interface name share one hover. Target files are never
opened, read, or force-loaded by this plugin.

An edit clears annotations immediately through `nvim_buf_attach` and cancels
obsolete work. Requeries wait for the debounce interval. Generation checks reject
late replies even when cancellation arrives too late. Changes invalidate all
tracked buffers sharing that gopls client: a method or interface in another file
can change the answer, so declaration-text caching alone would be unsound.

Other invalidation triggers are document open/close/save, changes to untracked
documents such as go.mod, workspace file/configuration/folder notifications,
gopls progress begin/end, and `workspace/codeLens/refresh` (the existing global
handler is preserved). gopls detach and buffer unload clear associated state.
Errors remain silent and retry on the next edit, semantic trigger, manual
refresh, or buffer entry. There is no polling loop. LSP does not define an
implementation-results refresh notification; an external change that Neovim
and gopls do not report requires `:GoImplementsRefresh`. Client-specific CodeLens
handlers override global handlers in Neovim and should call the global handler
if they want its invalidation behavior.

## Semantic and naming limits

- The annotation means **gopls reports an implementation relationship for this
  named type**. gopls includes pointer method sets: `implements io.Closer` above
  `File` may mean that `*File`, rather than a `File` value, implements it. The
  implementation response does not distinguish the two, so the plugin cannot
  label them separately without adding semantic analysis.
- gopls searches its workspace and indexed dependency scope, not every package
  on disk or every Go interface in existence. Empty interfaces such as `any`
  are intentionally omitted by gopls. Generic relationships and aliases follow
  the installed gopls version's behavior and limitations.
- Older gopls versions without type hierarchy support still handle explicit
  concrete type literals. Ambiguous named right-hand sides, including `int`, are
  conservatively skipped. Upgrade gopls for that coverage. Local types inside
  functions are not returned by gopls' document-symbol list and are not queried.
- LSP locations contain no names or package metadata. Qualified names use
  gopls' hover presentation, which is not a structured naming contract. With
  private symbols, plaintext hover, disabled links, or a changed hover format,
  the fallback is the unqualified name from the hover's type declaration. If
  that is unavailable, the annotation uses `filename:line`. No package name is
  guessed from an import path or filesystem layout. Unusual hover settings may
  therefore reduce naming quality without changing implementation results.

## Tests

Run the dependency-free mocked LSP suite:

```sh
nvim --headless -u NONE -l tests/run.lua
```

It covers one/multiple/external interfaces, empty results, interface exclusion,
multiple declarations, named-type classification, method edits across buffers,
missing gopls, stale replies, naming fallbacks, semantic refresh, setup lifecycle,
and request bounds for 200 declarations in a 10,201-line buffer.

Run the real gopls integration test (requires a recent gopls with type hierarchy):

```sh
GOPLS=/path/to/gopls nvim --headless -u NONE -l tests/integration.lua
```

The fixture uses standard-library interfaces, an external package whose name
differs from its directory, named scalar/slice/derived types, interface aliases,
pointer methods, and an unsaved method edit. It edits only Neovim's buffer and
does not write fixture files. Test caches are directed to `/tmp`.

API behavior was checked against Neovim's 0.10 client implementation and the
installed Neovim runtime, and against gopls v0.23.0 source and a live server:

- [Neovim 0.10 client API](https://github.com/neovim/neovim/blob/v0.10.4/runtime/lua/vim/lsp/client.lua)
- [gopls implementation queries](https://github.com/golang/tools/blob/gopls/v0.23.0/gopls/internal/golang/implementation.go)
- [gopls document symbols](https://github.com/golang/tools/blob/gopls/v0.23.0/gopls/internal/golang/symbols.go)
- [gopls type hierarchy](https://github.com/golang/tools/blob/gopls/v0.23.0/gopls/internal/golang/type_hierarchy.go)
- [gopls hover formatting](https://github.com/golang/tools/blob/gopls/v0.23.0/gopls/internal/golang/hover.go)

MIT licensed.
