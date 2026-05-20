/**
 * MosaicDB TypeScript/JavaScript SDK
 *
 * Federated Semantic Search & Code Graph client.
 *
 * @example
 * ```typescript
 * import { MosaicClient } from 'mosaicdb';
 *
 * const client = new MosaicClient('http://localhost:4040');
 *
 * // Search
 * const results = await client.search('error handling in auth', { limit: 5 });
 *
 * // Graph traversal
 * const callers = await client.traverse('execute_query', 'callers', 2);
 *
 * // RAG
 * const chunks = await client.rag('What is the auth flow?', { topK: 5 });
 *
 * // DuckDB analytics
 * const rows = await client.analytics('SELECT category, COUNT(*) FROM documents GROUP BY 1');
 * ```
 */

// ── Types ───────────────────────────────────────────────────────

export interface MosaicClientOptions {
  baseUrl?: string;
  apiKey?: string;
  jwtToken?: string;
  tenantId?: string;
  timeout?: number;
}

export interface SearchResult {
  id: string;
  name?: string;
  text?: string;
  similarity: number;
  metadata?: Record<string, unknown>;
  shard_id?: string;
  file_path?: string;
  source_text?: string;
}

export interface GraphNode {
  id: string;
  name: string;
  type: string;
  file?: string;
  file_path?: string;
  line?: number;
  start_line?: number;
  depth?: number;
  degree?: number;
}

export interface GraphReport {
  god_nodes: GraphNode[];
  bridge_nodes: GraphNode[];
  communities?: string[];
  questions?: string[];
}

export interface MemoryResult {
  id: string;
  session_id: string;
  type: 'episodic' | 'semantic' | 'procedural';
  content: string;
  importance: number;
  similarity: number;
  score: number;
  created_at: string;
  metadata?: Record<string, unknown>;
}

export interface RAGResult {
  query: string;
  chunks: SearchResult[];
  context: string;
  token_count: number;
}

export interface CacheStats {
  hits: number;
  misses: number;
  total: number;
  hit_rate: number;
  active_entries: number;
  tokens_saved: number;
  estimated_cost_saved: number;
}

export interface EvalReport {
  total_events: number;
  precision_at_5?: number;
  recall_at_10?: number;
  mrr?: number;
  ndcg_at_10?: number;
  avg_latency_ms?: number;
  p50_latency_ms?: number;
  p95_latency_ms?: number;
}

export interface MCPTool {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

export interface IngestResult {
  nodes_ingested?: number;
  edges_created?: number;
  files_processed?: number;
  errors?: string[];
}

// ── Client ──────────────────────────────────────────────────────

export class MosaicClient {
  private baseUrl: string;
  private apiKey?: string;
  private jwtToken?: string;
  private tenantId: string;
  private timeout: number;

  constructor(options: MosaicClientOptions | string = {}) {
    if (typeof options === 'string') {
      this.baseUrl = options.replace(/\/$/, '');
      options = {};
    } else {
      this.baseUrl = (options.baseUrl || 'http://localhost:4040').replace(/\/$/, '');
    }

    this.apiKey = options.apiKey || process.env.MOSAIC_API_KEY;
    this.jwtToken = options.jwtToken || process.env.MOSAIC_JWT_TOKEN;
    this.tenantId = options.tenantId || process.env.MOSAIC_TENANT_ID || 'default';
    this.timeout = options.timeout || 30000;
  }

  // ── HTTP ──────────────────────────────────────────────────

  private headers(): Record<string, string> {
    const h: Record<string, string> = { 'Content-Type': 'application/json' };
    if (this.apiKey) h['X-API-Key'] = this.apiKey;
    if (this.jwtToken) h['Authorization'] = `Bearer ${this.jwtToken}`;
    if (this.tenantId) h['X-Tenant-ID'] = this.tenantId;
    return h;
  }

  private async post<T>(path: string, data: Record<string, unknown>): Promise<T> {
    const resp = await fetch(`${this.baseUrl}${path}`, {
      method: 'POST',
      headers: this.headers(),
      body: JSON.stringify(data),
      signal: AbortSignal.timeout(this.timeout),
    });
    if (!resp.ok) {
      const errBody = await resp.json().catch(() => ({ error: `HTTP ${resp.status}` })) as Record<string, unknown>;
      throw new Error(String(errBody.error || `HTTP ${resp.status}: ${resp.statusText}`));
    }
    return resp.json() as Promise<T>;
  }

  private async get<T>(path: string): Promise<T> {
    const resp = await fetch(`${this.baseUrl}${path}`, {
      method: 'GET',
      headers: this.headers(),
      signal: AbortSignal.timeout(this.timeout),
    });
    if (!resp.ok) {
      throw new Error(`HTTP ${resp.status}: ${resp.statusText}`);
    }
    return resp.json() as Promise<T>;
  }

  // ── Search ────────────────────────────────────────────────

  async search(query: string, opts: {
    limit?: number;
    minSimilarity?: number;
    where?: string;
    hybrid?: boolean;
  } = {}): Promise<SearchResult[]> {
    const endpoint = (opts.hybrid || opts.where) ? '/api/search/hybrid' : '/api/search';
    const payload: Record<string, unknown> = {
      query,
      limit: opts.limit || 20,
      min_similarity: opts.minSimilarity || 0.1,
    };
    if (opts.where) payload.where = opts.where;
    const resp = await this.post<{ results: SearchResult[] }>(endpoint, payload);
    return resp.results;
  }

  async analytics(sql: string): Promise<unknown[][]> {
    const resp = await this.post<{ results: unknown[][] }>('/api/analytics', { sql });
    return resp.results;
  }

  // ── Graph ─────────────────────────────────────────────────
  
  async traverse(
    node: string,
    relation: 'callers' | 'callees' | 'ancestors' | 'descendants' | 'neighborhood' | 'dependents' = 'callers',
    depth: number = 1,
    limit: number = 50,
  ): Promise<GraphNode[]> {
    const resp = await this.post<{ results: GraphNode[] }>('/api/graph/traverse', {
      node, relation, depth, limit,
    });
    return resp.results;
  }

  async graphReport(godNodes: number = 10, bridgeNodes: number = 10): Promise<GraphReport> {
    return this.post<GraphReport>('/api/graph/report', {
      god_nodes: godNodes,
      bridge_nodes: bridgeNodes,
    });
  }

  // ── Ingestion ─────────────────────────────────────────────

  async ingestCode(path: string, opts: {
    language?: string;
    incremental?: boolean;
  } = {}): Promise<IngestResult> {
    return this.post<IngestResult>('/api/ingest/code', {
      path,
      language: opts.language,
      incremental: opts.incremental ?? true,
    });
  }

  async ingestDocs(path: string, opts: {
    chunkStrategy?: 'paragraph' | 'sentence' | 'fixed' | 'markdown' | 'sliding';
    chunkSize?: number;
    chunkOverlap?: number;
  } = {}): Promise<IngestResult> {
    return this.post<IngestResult>('/api/ingest/docs', {
      path,
      chunk_strategy: opts.chunkStrategy || 'paragraph',
      chunk_size: opts.chunkSize || 512,
      chunk_overlap: opts.chunkOverlap || 64,
    });
  }

  // ── RAG ───────────────────────────────────────────────────

  async rag(query: string, opts: {
    topK?: number;
    hybrid?: boolean;
    expandContext?: boolean;
  } = {}): Promise<RAGResult> {
    const endpoint = opts.hybrid ? '/api/rag/hybrid' : '/api/rag';
    return this.post<RAGResult>(endpoint, {
      query,
      top_k: opts.topK || 5,
      expand_context: opts.expandContext ?? true,
    });
  }

  async ragCompressed(query: string, topK: number = 10): Promise<string> {
    const resp = await this.post<{ stub: string }>('/api/rag/compressed', {
      query,
      top_k: topK,
    });
    return resp.stub;
  }

  // ── Agent Memory ──────────────────────────────────────────

  async remember(sessionId: string, content: string, opts: {
    type?: 'episodic' | 'semantic' | 'procedural';
    tags?: string[];
    importance?: number;
  } = {}): Promise<{ memory: MemoryResult; stub: string }> {
    return this.post<{ memory: MemoryResult; stub: string }>('/api/memory/remember', {
      session_id: sessionId,
      content,
      type: opts.type || 'episodic',
      tags: opts.tags || [],
      importance: opts.importance ?? 0.5,
    });
  }

  async recall(sessionId: string, query: string, opts: {
    limit?: number;
  } = {}): Promise<MemoryResult[]> {
    const resp = await this.post<{ memories: MemoryResult[] }>('/api/memory/recall', {
      session_id: sessionId,
      query,
      limit: opts.limit || 10,
    });
    return resp.memories;
  }

  async consolidateMemory(sessionId: string, olderThanHours: number = 24): Promise<unknown> {
    return this.post('/api/memory/consolidate', {
      session_id: sessionId,
      older_than_hours: olderThanHours,
    });
  }

  async memoryStats(sessionId: string): Promise<Record<string, unknown>> {
    return this.get<Record<string, unknown>>(`/api/memory/stats/${sessionId}`);
  }

  // ── Cache ─────────────────────────────────────────────────

  async cacheStats(): Promise<CacheStats> {
    return this.get<CacheStats>('/api/cache/stats');
  }

  async cachePurge(): Promise<void> {
    await this.post('/api/cache/purge', {});
  }

  // ── Eval ──────────────────────────────────────────────────

  async evalReport(metricType: string, window: string = 'day'): Promise<EvalReport> {
    return this.get<EvalReport>(`/api/eval/report/${metricType}?last=${window}`);
  }

  // ── Auth ──────────────────────────────────────────────────

  async login(username: string, password: string): Promise<{ token: string }> {
    const resp = await this.post<{ token: string }>('/api/auth/login', { username, password });
    if (resp.token) this.jwtToken = resp.token;
    return resp;
  }

  async createApiKey(scopes: string[]): Promise<{ key: string; key_id: string }> {
    return this.post<{ key: string; key_id: string }>('/api/auth/keys', { scopes });
  }

  // ── Status & Health ───────────────────────────────────────

  async health(): Promise<string> {
    const resp = await fetch(`${this.baseUrl}/health`, {
      signal: AbortSignal.timeout(this.timeout),
    });
    return resp.text();
  }

  async status(): Promise<Record<string, unknown>> {
    return this.get<Record<string, unknown>>('/api/status');
  }

  async metrics(): Promise<Record<string, unknown>> {
    return this.get<Record<string, unknown>>('/api/metrics');
  }

  // ── MCP ───────────────────────────────────────────────────

  async mcpTools(): Promise<MCPTool[]> {
    return this.post<MCPTool[]>('/mcp', {
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/list',
      params: {},
    });
  }

  async mcpCall(tool: string, args: Record<string, unknown>): Promise<unknown> {
    return this.post('/mcp', {
      jsonrpc: '2.0',
      id: 1,
      method: 'tools/call',
      params: { name: tool, arguments: args },
    });
  }

  // ── Tenant Management ─────────────────────────────────────

  async createTenant(tenantId: string, name: string): Promise<Record<string, unknown>> {
    return this.post('/api/tenants', { tenant_id: tenantId, name });
  }

  async getTenant(tenantId: string): Promise<Record<string, unknown>> {
    return this.get(`/api/tenants/${tenantId}`);
  }

  // ── Session ───────────────────────────────────────────────

  setApiKey(key: string): void { this.apiKey = key; }
  setJwtToken(token: string): void { this.jwtToken = token; }
  setTenantId(id: string): void { this.tenantId = id; }
}
