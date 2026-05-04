# reify/ — S-Expression → Framework Transpiler

Plugin-based transpiler that converts S-expression DSLs into React JSX,
Vue SFC, and plain HTML. Round-trip capable. Caches reified components
in the graph.

## Modules

- `reify.ex` — Entry point: transpile, parse, plugin registry
- `plugin.ex` — Behaviour for reify plugins (name/0, transpile/2)
- `ast.ex` — Typed AST: Node, Attr, Expr structs with from_sexpr/1
- `parser.ex` — Character-level S-expression tokenizer with string support
- `react.ex` — React/JSX transpiler with conditionals, loops, dynamic attrs
- `vue.ex` — Vue 3 SFC transpiler with @click, v-if, v-for, v-model
- `html.ex` — Plain HTML transpiler with onclick, data attributes
- `cache.ex` — Store reified components as graph nodes for caching

## Isolation

- **Depends on**: `graph/writer.ex` (cache.ex only)
- **Does NOT depend on**: graph/traversal, ast, document, vector, rag, auth, tenancy
- **Consumed by**: bin/mosaic (mosaic reify), mix mosaic.dev (dev server)
- **Platform layers**: none needed — reify is a standalone transpiler

## Adding a New Framework

1. Create `reify/svelte.ex` (for example)
2. Implement `@behaviour Mosaic.Reify.Plugin`
3. Add to `Mosaic.Reify.plugins/0` list
4. Add framework-specific CSS file for rendered output
