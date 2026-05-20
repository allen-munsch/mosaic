#!/usr/bin/env elixir
# ── MosaicDB — Codebase Graph Explorer ────────────────────────────
# Ingests the MosaicDB codebase, generates an interactive graph HTML
# with click-to-expand traversal, search, and module collapsing.
#
# Usage:
#   mix run scripts/rag_demo.exs          # full: parse + embed + html
#   mix run scripts/rag_demo.exs --fast   # skip embeddings (faster)
#   open mosaic_graph.html
# ──────────────────────────────────────────────────────────────────

fast_mode = "--fast" in System.argv()

IO.puts("\n#{IO.ANSI.bright()}#{IO.ANSI.cyan()}╔══════════════════════════════════════════════╗#{IO.ANSI.reset()}")
IO.puts("#{IO.ANSI.bright()}#{IO.ANSI.cyan()}║   MosaicDB — Codebase Graph Explorer       ║#{IO.ANSI.reset()}")
IO.puts("#{IO.ANSI.bright()}#{IO.ANSI.cyan()}╚══════════════════════════════════════════════╝#{IO.ANSI.reset()}")

Application.put_env(:mosaic, :http_port, 0)
Application.ensure_all_started(:mosaic)

alias Mosaic.AST.BuiltinParser
alias Mosaic.Graph.Writer

# ═══════════════════════════════════════════════
# Phase 1 — Parse entire codebase fast
# ═══════════════════════════════════════════════
IO.puts("\n#{IO.ANSI.yellow()}📦 Parsing MosaicDB codebase...#{IO.ANSI.reset()}")

storage = Mosaic.Config.get(:storage_path)
ts = System.monotonic_time()
shard = Path.join(storage, "graph_explorer_#{ts}.db")
Mosaic.StorageManager.create_shard(shard)

# Ingest ALL files for comprehensive graph
files = Path.wildcard("lib/mosaic/**/*.ex")
|> Enum.filter(&File.regular?/1)

IO.puts("   Found #{length(files)} files...")

{all_nodes, all_edges, errors} =
  Enum.reduce(files, {[], [], 0}, fn f, {na, ea, er} ->
    case File.read(f) do
      {:ok, src} ->
        {ns, es} =
          cond do
            String.ends_with?(f, ".ex") or String.ends_with?(f, ".exs") ->
              BuiltinParser.extract_elixir(src, f)
            true -> {[], []}
          end
        IO.write(".")
        {na ++ ns, ea ++ es, er}
      {:error, _} -> IO.write("x"); {na, ea, er + 1}
    end
  end)

t_parse = System.monotonic_time() - ts
IO.puts("\n   ✅ #{length(all_nodes)} nodes, #{length(all_edges)} edges in #{div(t_parse, 1000)}ms (#{errors} errors)")

# ═══════════════════════════════════════════════
# Phase 2 — Embeddings (skip in fast mode)
# ═══════════════════════════════════════════════
enriched = if fast_mode do
  IO.puts("\n#{IO.ANSI.yellow()}⚡ Fast mode: skipping embeddings#{IO.ANSI.reset()}")
  Enum.map(all_nodes, fn n -> Map.put(n, :embedding, List.duplicate(0.0, 384)) end)
else
  IO.puts("\n#{IO.ANSI.yellow()}🔢 Generating embeddings (batched)...#{IO.ANSI.reset()}")
  texts = Enum.map(all_nodes, fn n -> n.source_text || n.name || "" end)
  t0 = System.monotonic_time(:millisecond)
  embeddings = Mosaic.EmbeddingService.encode_batch(texts)
  t1 = System.monotonic_time(:millisecond)
  IO.puts("   ✅ #{length(embeddings)} vectors in #{t1 - t0}ms (#{Float.round((t1 - t0) / max(length(embeddings), 1), 1)}ms/node)")

  Enum.zip(all_nodes, embeddings)
  |> Enum.map(fn {n, e} -> Map.put(n, :embedding, e) end)
end

# ═══════════════════════════════════════════════
# Phase 3 — Write to shard
# ═══════════════════════════════════════════════
IO.puts("\n#{IO.ANSI.yellow()}💾 Writing to SQLite shard...#{IO.ANSI.reset()}")

{:ok, stats} = Writer.write_subgraph(shard, enriched, all_edges)
IO.puts("   ✅ #{stats.nodes_written} nodes, #{stats.edges_written} edges")

try do
  Mosaic.ShardRouter.reset_state()
  Mosaic.ShardRouter.register_shard(%{
    id: "graph_explorer_#{ts}", path: shard,
    centroids: %{document: List.duplicate(0.0, 384)},
    doc_count: length(enriched), bloom_filter: nil
  })
rescue _ -> :ok
end

# ═══════════════════════════════════════════════
# Phase 4 — SQL Analytics
# ═══════════════════════════════════════════════
IO.puts("\n#{IO.ANSI.yellow()}📊 SQL Analytics#{IO.ANSI.reset()}")

{:ok, conn} = Mosaic.ConnectionPool.checkout(shard)

{:ok, [[total_nodes]]} = Mosaic.DB.query(conn, "SELECT COUNT(*) FROM nodes")
{:ok, [[total_edges]]} = Mosaic.DB.query(conn, "SELECT COUNT(*) FROM edges")

{:ok, type_dist} = Mosaic.DB.query(conn,
  "SELECT type, COUNT(*) c FROM nodes GROUP BY type ORDER BY c DESC")

{:ok, edge_dist} = Mosaic.DB.query(conn,
  "SELECT type, COUNT(*) c FROM edges GROUP BY type ORDER BY c DESC")

{:ok, top_modules} = Mosaic.DB.query(conn, """
  SELECT n1.name, COUNT(*) c FROM nodes n1
  JOIN nodes n2 ON n2.parent_id = n1.id
  WHERE n1.type = 'module' AND n2.type = 'function'
  GROUP BY n1.name ORDER BY c DESC LIMIT 10
""")

# Build adjacency index: for each node, store its neighbors
IO.puts("   Building adjacency index...")
{:ok, adjacency_rows} = Mosaic.DB.query(conn, """
  SELECT e.source_id, e.target_id, e.type, ns.name as sname, ns.type as stype,
         nt.name as tname, nt.type as ttype
  FROM edges e
  JOIN nodes ns ON e.source_id = ns.id
  JOIN nodes nt ON e.target_id = nt.id
  LIMIT 5000
""")

# Group edges by source node
adjacency = Enum.group_by(adjacency_rows, fn [sid | _] -> sid end)
|> Map.new(fn {sid, rows} ->
  edges = Enum.map(rows, fn [_sid, tid, etype, _sn, _st, tn, tt] ->
    %{target: tid, type: etype, name: tn, ttype: tt}
  end)
  {sid, edges}
end)

# Also compute reverse adjacency (incoming edges)
reverse_adj = Enum.group_by(adjacency_rows, fn [_sid, tid | _] -> tid end)
|> Map.new(fn {tid, rows} ->
  edges = Enum.map(rows, fn [sid, _tid, etype, sn, st, _tn, _tt] ->
    %{source: sid, type: etype, name: sn, stype: st}
  end)
  {tid, edges}
end)

Mosaic.ConnectionPool.checkin(shard, conn)

IO.puts("   Adjacency: #{map_size(adjacency)} nodes with outgoing edges, #{map_size(reverse_adj)} with incoming")

# ═══════════════════════════════════════════════
# Phase 5 — Build graph JSON with adjacency
# ═══════════════════════════════════════════════
IO.puts("\n#{IO.ANSI.yellow()}🕸️  Building graph JSON...#{IO.ANSI.reset()}")

# Group nodes by parent module for hierarchy
nodes_by_parent = Enum.group_by(all_nodes, &(&1.parent_id || "__root__"))
module_nodes = Enum.filter(all_nodes, &(&1.type == "module"))

# Build clean node list
display_nodes = all_nodes
|> Enum.map(fn node ->
  %{
    id: node.id,
    name: (node.name || "?") |> String.replace(~s("), ~s(\\")),
    type: node.type || "unknown",
    file: (node.file_path || "") |> String.replace_prefix(File.cwd!() <> "/", ""),
    parent: node.parent_id,
    preview: (node.source_text || "") |> String.slice(0, 120) |> String.replace(~s("), ~s(\\")),
    childCount: length(Map.get(nodes_by_parent, node.id, [])),
  }
end)

node_ids = MapSet.new(display_nodes, & &1.id)
node_map = Map.new(display_nodes, &{&1.id, &1})

# Keep only edges within our node set, deduplicate
display_edges = all_edges
|> Enum.filter(fn e ->
  sid = Map.get(e, :source_id) || Map.get(e, :source)
  tid = Map.get(e, :target_id) || Map.get(e, :target)
  MapSet.member?(node_ids, sid) && MapSet.member?(node_ids, tid)
end)
|> Enum.uniq_by(fn e ->
  sid = Map.get(e, :source_id) || Map.get(e, :source)
  tid = Map.get(e, :target_id) || Map.get(e, :target)
  {sid, tid, e.type}
end)
|> Enum.map(fn e ->
  %{
    source: Map.get(e, :source_id) || Map.get(e, :source),
    target: Map.get(e, :target_id) || Map.get(e, :target),
    type: e.type || "unknown",
  }
end)

# Embed adjacency data in nodes for client-side traversal
nodes_with_adj = Enum.map(display_nodes, fn n ->
  out_edges = Map.get(adjacency, n.id, [])
  in_edges = Map.get(reverse_adj, n.id, [])
  Map.put(n, :adjacency, %{
    outgoing: Enum.take(out_edges, 50),
    incoming: Enum.take(in_edges, 50)
  })
end)

IO.puts("   ✅ #{length(nodes_with_adj)} nodes, #{length(display_edges)} edges")

# ═══════════════════════════════════════════════
# Phase 6 — Generate interactive HTML
# ═══════════════════════════════════════════════
IO.puts("\n#{IO.ANSI.yellow()}🌐 Generating graph explorer HTML...#{IO.ANSI.reset()}")

graph_json = Jason.encode!(%{
  nodes: nodes_with_adj,
  links: display_edges,
  modules: Enum.map(module_nodes, fn m ->
    children = Map.get(nodes_by_parent, m.id, [])
    %{
      id: m.id,
      name: m.name,
      file: m.file_path,
      childCount: length(children),
      childIds: Enum.map(children, & &1.id)
    }
  end)
})

stats_json = Jason.encode!(%{
  total_nodes: total_nodes,
  total_edges: total_edges,
  type_dist: Enum.map(type_dist, fn [t, c] -> %{type: t, count: c} end),
  edge_dist: Enum.map(edge_dist, fn [t, c] -> %{type: t, count: c} end),
  top_modules: Enum.map(top_modules, fn [m, c] -> %{name: String.replace_prefix(m, "Mosaic.", ""), count: c} end),
  fast_mode: fast_mode,
  parse_time_ms: div(t_parse, 1000),
})

# Build adjacency lookup for client-side
adjacency_json = Jason.encode!(adjacency |> Map.new(fn {k, v} -> {k, Enum.take(v, 50)} end))
rev_adj_json = Jason.encode!(reverse_adj |> Map.new(fn {k, v} -> {k, Enum.take(v, 50)} end))

html = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>MosaicDB — Codebase Graph Explorer</title>
<script src="https://d3js.org/d3.v7.min.js"></script>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:ui-monospace,SFMono-Regular,'SF Mono',Menlo,Consolas,monospace;background:#0a0e14;color:#bfbab0;overflow:hidden}
#app{display:flex;height:100vh}
#sidebar{width:360px;background:#0f1419;border-right:1px solid #1f2a33;display:flex;flex-direction:column;font-size:12px}
#sidebar h2{padding:14px 16px;font-size:15px;border-bottom:1px solid #1f2a33;color:#ffb454;letter-spacing:.5px}
#search-wrap{position:relative;margin:10px 12px}
#search{width:100%;padding:8px 28px 8px 12px;background:#0a0e14;border:1px solid #1f2a33;border-radius:4px;color:#bfbab0;font-family:inherit;font-size:12px}
#search:focus{outline:none;border-color:#ffb454}
#search-icon{position:absolute;right:10px;top:50%;transform:translateY(-50%);color:#4a5568}
#quick-nav{padding:0 12px 8px;display:flex;gap:4px;flex-wrap:wrap}
.qnav-btn{padding:3px 8px;border:1px solid #1f2a33;border-radius:3px;background:transparent;color:#8b949e;cursor:pointer;font-family:inherit;font-size:11px;transition:all .15s}
.qnav-btn:hover{background:#1f2a33;color:#bfbab0}
.qnav-btn.active{background:#2d1a00;border-color:#ffb454;color:#ffb454}
#filters{padding:0 12px 8px;display:flex;gap:4px}
.fbtn{padding:3px 10px;border:1px solid #1f2a33;border-radius:3px;background:transparent;color:#8b949e;cursor:pointer;font-family:inherit;font-size:11px;transition:all .15s}
.fbtn:hover{background:#1f2a33}
.fbtn.on{border-color:#ffb454;color:#ffb454}
.fbtn.module{border-color:#59c2ff;color:#59c2ff}
.fbtn.function{border-color:#7fd962;color:#7fd962}
.fbtn.import{border-color:#ffb454;color:#ffb454}
#stats{padding:12px;border-top:1px solid #1f2a33;font-size:11px;color:#8b949e;overflow-y:auto;flex:1}
#stats h3{color:#ffb454;margin:8px 0 4px;font-size:12px;text-transform:uppercase;letter-spacing:.5px}
.srow{display:flex;justify-content:space-between;padding:1px 0}
#detail{padding:12px;border-top:1px solid #1f2a33;font-size:11px;max-height:220px;overflow-y:auto;background:#0a0e14}
#detail h4{color:#59c2ff;margin-bottom:2px;font-size:12px}
#detail .meta{color:#8b949e;font-size:10px;margin-bottom:4px}
#detail .meta span{margin-right:12px}
#detail .code{color:#bfbab0;font-size:10px;line-height:1.4;background:#0f1419;padding:6px 8px;border-radius:3px;white-space:pre-wrap;word-break:break-all;border:1px solid #1f2a33}
#detail .actions{display:flex;gap:4px;margin-top:6px}
#detail .actions button{padding:3px 8px;border:1px solid #1f2a33;border-radius:3px;background:transparent;color:#8b949e;cursor:pointer;font-family:inherit;font-size:10px}
#detail .actions button:hover{background:#1f2a33;color:#bfbab0}
#detail .adj{margin-top:8px}
#detail .adj .dir{font-size:10px;color:#8b949e;margin-bottom:2px}
#detail .adj .item{display:inline-block;margin:1px 4px 1px 0;padding:1px 6px;border-radius:3px;font-size:10px;cursor:pointer;transition:all .15s}
#detail .adj .item:hover{opacity:.8}
#detail .adj .item.calls{background:#1a2b3c;color:#59c2ff}
#detail .adj .item.contains{background:#1a2e1a;color:#7fd962}
#detail .adj .item.imports{background:#2d1a00;color:#ffb454}
#graph-container{flex:1;position:relative}
#tooltip{position:absolute;background:#0f1419;border:1px solid #1f2a33;border-radius:4px;padding:8px 12px;font-size:11px;pointer-events:none;opacity:0;z-index:10;max-width:300px;box-shadow:0 4px 12px rgba(0,0,0,.4)}
#tooltip .tt-n{color:#59c2ff;font-weight:600}
#tooltip .tt-t{color:#8b949e}
#legend{position:absolute;bottom:10px;left:12px;display:flex;gap:16px;font-size:10px;color:#8b949e}
.ldot{width:8px;height:8px;border-radius:50%;display:inline-block;margin-right:4px}
#hint{position:absolute;bottom:10px;right:16px;font-size:10px;color:#4a5568}
svg{width:100%;height:100%}
.link{stroke-opacity:.12}
.link.calls{stroke:#59c2ff}
.link.contains{stroke:#7fd962}
.link.imports{stroke:#ffb454}
.link.highlight{stroke-opacity:.6;stroke-width:2}
.node{cursor:pointer}
.node text{font-size:8px;fill:#8b949e;pointer-events:none;font-family:inherit}
.node text.module{fill:#59c2ff;font-size:10px;font-weight:600}
.node.highlight text{fill:#fff}
.node.dimmed{opacity:.08}
.node.focused text{fill:#fff;font-size:11px;font-weight:700}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
.node.selected{animation:pulse 1.5s ease-in-out infinite}
</style>
</head>
<body>
<div id="app">
<div id="sidebar">
<h2>◈ MosaicDB Explorer</h2>
<div id="search-wrap">
  <input id="search" placeholder="Search nodes (regex)..." autofocus>
  <span id="search-icon">⌕</span>
</div>
<div id="quick-nav"></div>
<div id="filters">
  <button class="fbtn on" data-type="all">all</button>
  <button class="fbtn module" data-type="module">modules</button>
  <button class="fbtn function" data-type="function">functions</button>
  <button class="fbtn import" data-type="import">imports</button>
</div>
<div id="stats"></div>
<div id="detail">
  <em style="color:#3a4450">↖ Click a node to inspect<br>↖ Double-click to expand neighbors<br>↖ Shift+click for path finding</em>
</div>
</div>
<div id="graph-container">
<svg id="graph"></svg>
<div id="tooltip"></div>
<div id="legend">
  <span><span class="ldot" style="background:#59c2ff"></span>calls</span>
  <span><span class="ldot" style="background:#7fd962"></span>contains</span>
  <span><span class="ldot" style="background:#ffb454"></span>imports</span>
</div>
<div id="hint">drag · scroll · ⌘K search · esc clear</div>
</div>
</div>

<script>
const DATA = #{graph_json};
const STATS = #{stats_json};
const ADJ = #{adjacency_json};
const REV = #{rev_adj_json};

// ── State ──────────────────────────────────────
let activeType = 'all';
let searchRe = null;
let selectedNode = null;
let pathSource = null;
let expandedNodes = new Set();
let collapsedModules = new Set();
let nodeMap = new Map(DATA.nodes.map(n => [n.id, n]));
let edgeMap = new Map();

// ── Colors ─────────────────────────────────────
const COLORS = { module:'#59c2ff','function':'#7fd962','import':'#ffb454','class':'#f778ba','struct':'#95e6cb','trait':'#d2a8ff',unknown:'#4a5568' };
const TYPE_RANK = {module:0,'function':1,'class':2,struct:3,trait:4,'import':5,unknown:6};

// ── Sidebar stats ──────────────────────────────
function buildStats() {
  const m = DATA.modules ? DATA.modules.length : 0;
  document.getElementById('stats').innerHTML = `
    <h3>Graph</h3>
    <div class="srow"><span>nodes</span><span>${STATS.total_nodes}</span></div>
    <div class="srow"><span>edges</span><span>${STATS.total_edges}</span></div>
    <div class="srow"><span>modules</span><span>${m}</span></div>
    <div class="srow"><span>ingest</span><span>${STATS.parse_time_ms}ms${STATS.fast_mode?' (fast)':''}</span></div>
    <h3>Types</h3>
    ${STATS.type_dist.map(d => `<div class="srow"><span>${d.type}</span><span>${d.count}</span></div>`).join('')}
    <h3>Edges</h3>
    ${STATS.edge_dist.map(d => `<div class="srow"><span>${d.type}</span><span>${d.count}</span></div>`).join('')}
    <h3>Top Modules</h3>
    ${STATS.top_modules.map(m => `<div class="srow"><span>${m.name}</span><span>${m.count} fns</span></div>`).join('')}
  `;
}
buildStats();

// ── SVG setup ──────────────────────────────────
const container = document.getElementById('graph-container');
const svg = d3.select('#graph');
const W = container.clientWidth, H = container.clientHeight;
svg.attr('viewBox', [0, 0, W, H]);
const g = svg.append('g');
const zoom = d3.zoom().scaleExtent([0.08, 6]).on('zoom', e => g.attr('transform', e.transform));
svg.call(zoom);
svg.call(zoom.transform, d3.zoomIdentity.translate(W/2, H/2));

// ── Force simulation ───────────────────────────
let sim = d3.forceSimulation(DATA.nodes)
  .force('link', d3.forceLink(DATA.links).id(d => d.id).distance(d => d.type === 'contains' ? 35 : 60))
  .force('charge', d3.forceManyBody().strength(d => d.type === 'module' ? -250 : -80))
  .force('center', d3.forceCenter(0, 0))
  .force('collide', d3.forceCollide(d => d.type === 'module' ? 25 : 12))
  .alphaDecay(0.02);

// ── Render ─────────────────────────────────────
const link = g.append('g').selectAll('line').data(DATA.links).join('line')
  .attr('class', d => 'link ' + (d.type||'')).attr('stroke-width', d => d.type==='contains'?1.5:0.8);

const node = g.append('g').selectAll('g').data(DATA.nodes).join('g')
  .attr('class', 'node')
  .call(d3.drag()
    .on('start',(e,d)=>{if(!e.active)sim.alphaTarget(0.3).restart();d.fx=d.x;d.fy=d.y})
    .on('drag',(e,d)=>{d.fx=e.x;d.fy=e.y})
    .on('end',(e,d)=>{if(!e.active)sim.alphaTarget(0);d.fx=null;d.fy=null})
  );

node.append('circle')
  .attr('r', d => d.type==='module'?9:d.type==='function'?4.5:3.5)
  .attr('fill', d => COLORS[d.type]||COLORS.unknown)
  .attr('stroke', '#0a0e14').attr('stroke-width', d => d.type==='module'?2:1);

node.append('text')
  .text(d => d.name.length > 22 ? d.name.slice(0,20)+'…' : d.name)
  .attr('class', d => d.type==='module'?'module':'')
  .attr('dx', d => d.type==='module'?12:8).attr('dy', 3);

// ── Tick ───────────────────────────────────────
sim.on('tick', () => {
  link.attr('x1',d=>d.source.x).attr('y1',d=>d.source.y).attr('x2',d=>d.target.x).attr('y2',d=>d.target.y);
  node.attr('transform', d => `translate(${d.x},${d.y})`);
});

// ── Tooltip ────────────────────────────────────
const tip = document.getElementById('tooltip');
node.on('mouseover', (e,d) => {
  tip.style.opacity=1; tip.style.left=(e.pageX+14)+'px'; tip.style.top=(e.pageY-8)+'px';
  tip.innerHTML=`<div class="tt-n">${d.name}</div><div class="tt-t">${d.type} · ${d.file||''}</div><div class="tt-t" style="font-size:10px">edges: ${(ADJ[d.id]||[]).length} out, ${(REV[d.id]||[]).length} in</div>`;
}).on('mousemove', e => { tip.style.left=(e.pageX+14)+'px'; tip.style.top=(e.pageY-8)+'px' })
  .on('mouseout', () => tip.style.opacity=0);

// ── Click: select + show detail ────────────────
function showDetail(d) {
  const adj = d.adjacency || {outgoing:[],incoming:[]};
  const outHtml = adj.outgoing.slice(0,15).map(e =>
    `<span class="item ${e.type}" data-nid="${e.target}">${e.name||e.target} →</span>`
  ).join('');
  const inHtml = adj.incoming.slice(0,15).map(e =>
    `<span class="item ${e.type}" data-nid="${e.source}">← ${e.name||e.source}</span>`
  ).join('');

  document.getElementById('detail').innerHTML = `
    <h4>${d.name}</h4>
    <div class="meta"><span>${d.type}</span><span>${d.file||''}</span><span>${d.childCount||0} children</span></div>
    ${d.preview ? `<div class="code">${d.preview}</div>` : ''}
    <div class="actions">
      <button id="btn-expand">↗ expand neighbors</button>
      <button id="btn-path-from">⊸ path from here</button>
      <button id="btn-path-to">⊸ path to here</button>
      <button id="btn-clear">✕ clear</button>
    </div>
    <div class="adj">
      ${outHtml ? `<div class="dir">→ outgoing (${adj.outgoing.length})</div><div>${outHtml}</div>` : ''}
      ${inHtml ? `<div class="dir" style="margin-top:6px">← incoming (${adj.incoming.length})</div><div>${inHtml}</div>` : ''}
    </div>
  `;

  // Wire up buttons
  document.getElementById('btn-expand')?.addEventListener('click', () => expandNode(d));
  document.getElementById('btn-path-from')?.addEventListener('click', () => { pathSource = d; highlightPathFrom(d); });
  document.getElementById('btn-path-to')?.addEventListener('click', () => { if(pathSource) highlightPath(pathSource, d); });
  document.getElementById('btn-clear')?.addEventListener('click', clearSelection);
  document.querySelectorAll('#detail .adj .item').forEach(el => {
    el.addEventListener('click', () => {
      const nid = el.dataset.nid;
      const n = nodeMap.get(nid);
      if (n) { showDetail(n); zoomToNode(n); }
    });
  });
}

function zoomToNode(d) {
  const tx = W/2 - d.x * 2, ty = H/2 - d.y * 2;
  svg.transition().duration(500).call(zoom.transform, d3.zoomIdentity.translate(tx, ty).scale(2));
}

// ── Expand: show neighbors ─────────────────────
function expandNode(d) {
  const adj = ADJ[d.id] || [];
  const rev = REV[d.id] || [];
  const neighborIds = new Set([...adj.map(e=>e.target), ...rev.map(e=>e.source)]);
  expandedNodes.add(d.id);

  // Highlight this node + neighbors
  node.classed('dimmed', n => {
    if (n.id === d.id) return false;
    return !neighborIds.has(n.id);
  });
  node.classed('focused', n => n.id === d.id);
  link.classed('highlight', l => {
    const sid = l.source.id || l.source;
    const tid = l.target.id || l.target;
    return sid === d.id || tid === d.id;
  });
  link.classed('dimmed', l => {
    const sid = l.source.id || l.source;
    const tid = l.target.id || l.target;
    return sid !== d.id && tid !== d.id && !(neighborIds.has(sid) && neighborIds.has(tid));
  });

  zoomToNode(d);
}

// ── Path highlighting ──────────────────────────
function highlightPathFrom(d) {
  pathSource = d;
  node.classed('selected', n => n.id === d.id);
  document.getElementById('detail').innerHTML += '<div style="color:#ffb454;margin-top:4px;font-size:10px">✓ source set — now click a target node or use "path to here"</div>';
}

function highlightPath(source, target) {
  // Simple BFS through adjacency
  const visited = new Set([source.id]);
  const parent = new Map();
  const queue = [source.id];
  let found = false;

  while (queue.length && !found) {
    const cur = queue.shift();
    const neighbors = [...(ADJ[cur]||[]), ...(REV[cur]||[]).map(e=>({target:e.source,type:e.type}))];
    for (const n of neighbors) {
      const nid = n.target || n.source;
      if (!visited.has(nid)) {
        visited.add(nid);
        parent.set(nid, cur);
        queue.push(nid);
        if (nid === target.id) { found = true; break; }
      }
    }
  }

  if (found) {
    const path = [target.id];
    let cur = target.id;
    while (parent.has(cur)) { cur = parent.get(cur); path.unshift(cur); }
    const pathSet = new Set(path);

    node.classed('dimmed', n => !pathSet.has(n.id));
    link.classed('highlight', l => {
      const sid = l.source.id || l.source;
      const tid = l.target.id || l.target;
      const si = path.indexOf(sid), ti = path.indexOf(tid);
      return si >= 0 && ti >= 0 && Math.abs(ti - si) === 1;
    });
    node.classed('selected', n => n.id === source.id || n.id === target.id);

    document.getElementById('detail').innerHTML += `<div style="color:#7fd962;margin-top:4px;font-size:10px">✓ path found: ${path.length} hops</div>`;
  } else {
    document.getElementById('detail').innerHTML += '<div style="color:#f778ba;margin-top:4px;font-size:10px">✕ no path found</div>';
  }
  pathSource = null;
}

// ── Clear selection ────────────────────────────
function clearSelection() {
  selectedNode = null; pathSource = null; expandedNodes.clear();
  node.classed('dimmed', false).classed('focused', false).classed('selected', false);
  link.classed('highlight', false).classed('dimmed', false);
  document.getElementById('detail').innerHTML = '<em style="color:#3a4450">↖ Click a node to inspect<br>↖ Double-click to expand neighbors<br>↖ Shift+click for path finding</em>';
  applyFilters();
}

// ── Node click handler ─────────────────────────
node.on('click', (e, d) => {
  if (e.shiftKey) {
    // Shift+click: path finding
    if (pathSource && pathSource.id !== d.id) {
      highlightPath(pathSource, d);
    } else {
      highlightPathFrom(d);
    }
  } else {
    showDetail(d);
    zoomToNode(d);
  }
});

node.on('dblclick', (e, d) => {
  expandNode(d);
  showDetail(d);
});

// ── Apply filters ──────────────────────────────
function applyFilters() {
  node.classed('dimmed', d => {
    if (activeType !== 'all' && d.type !== activeType) return true;
    if (searchRe && !searchRe.test(d.name) && !searchRe.test(d.type) && !searchRe.test(d.file||'')) return true;
    return false;
  });
  link.classed('dimmed', l => {
    const sn = nodeMap.get(l.source.id||l.source);
    const tn = nodeMap.get(l.target.id||l.target);
    if (!sn || !tn) return true;
    if (activeType !== 'all' && sn.type !== activeType && tn.type !== activeType) return true;
    if (searchRe && !searchRe.test(sn.name) && !searchRe.test(tn.name)) return true;
    return false;
  });
}

// ── Search ─────────────────────────────────────
document.getElementById('search').addEventListener('input', e => {
  const q = e.target.value.trim();
  searchRe = q ? new RegExp(q.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'), 'i') : null;
  applyFilters();
  updateQuickNav(q);
});

// ── Quick nav: matching modules ────────────────
function updateQuickNav(q) {
  const nav = document.getElementById('quick-nav');
  if (!q || q.length < 2) { nav.innerHTML = ''; return; }
  const re = new RegExp(q.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'), 'i');
  const matches = DATA.nodes.filter(n => re.test(n.name) || re.test(n.file||'')).slice(0, 8);
  nav.innerHTML = matches.map(n =>
    `<button class="qnav-btn" data-nid="${n.id}">${n.name.slice(0,30)}</button>`
  ).join('');
  nav.querySelectorAll('.qnav-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      const n = nodeMap.get(btn.dataset.nid);
      if (n) { showDetail(n); zoomToNode(n); }
    });
  });
}

// ── Type filters ───────────────────────────────
document.querySelectorAll('.fbtn').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.fbtn').forEach(b => b.classList.remove('on'));
    btn.classList.add('on');
    activeType = btn.dataset.type;
    applyFilters();
  });
});

// ── Keyboard shortcuts ─────────────────────────
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') { clearSelection(); document.getElementById('search').value=''; searchRe=null; applyFilters(); updateQuickNav(''); }
  if ((e.metaKey || e.ctrlKey) && e.key === 'k') { e.preventDefault(); document.getElementById('search').focus(); }
  if (e.key === 'f' && !e.metaKey && !e.ctrlKey && document.activeElement !== document.getElementById('search')) {
    e.preventDefault(); document.getElementById('search').focus();
  }
});

// ── Initial render: show top modules, dim others ──
const topModuleIds = new Set((DATA.modules||[]).slice(0,8).map(m => m.id));
node.classed('dimmed', d => d.type === 'function' && !topModuleIds.has(d.parent));
link.classed('dimmed', l => {
  const sn = nodeMap.get(l.source.id||l.source);
  const tn = nodeMap.get(l.target.id||l.target);
  return (sn?.type === 'function' && !topModuleIds.has(sn?.parent)) ||
         (tn?.type === 'function' && !topModuleIds.has(tn?.parent));
});
</script>
</body>
</html>
"""

output_path = Path.join(File.cwd!(), "mosaic_graph.html")
File.write!(output_path, html)

# ═══════════════════════════════════════════════
IO.puts("""

#{IO.ANSI.bright()}#{IO.ANSI.cyan()}══════════════════════════════════════════════#{IO.ANSI.reset()}
  ✅ MosaicDB Graph Explorer Ready

  📦 #{length(files)} files → #{length(all_nodes)} nodes, #{length(all_edges)} edges
  ⚡ Parse time: #{div(t_parse, 1000)}ms#{(fast_mode && " (fast mode — no embeddings)") || ""}
  🌐 #{IO.ANSI.green()}mosaic_graph.html#{IO.ANSI.reset()} (#{div(byte_size(html), 1024)}KB)

  #{IO.ANSI.bright()}Open:#{IO.ANSI.reset()}  #{IO.ANSI.cyan()}open mosaic_graph.html#{IO.ANSI.reset()}

  #{IO.ANSI.bright()}Interactions:#{IO.ANSI.reset()}
    🖱️  Click node     — inspect details + source preview
    🖱️  Double-click   — expand to show neighbors
    ⌨️  Shift+click    — path finding between nodes
    ⌨️  ⌘K / f         — focus search bar
    ⌨️  Esc            — clear selection
    🔍 Search          — regex filter with quick-nav dropdown
    🎨 Type filters    — isolate modules/functions/imports
#{IO.ANSI.bright()}#{IO.ANSI.cyan()}══════════════════════════════════════════════#{IO.ANSI.reset()}
""")
