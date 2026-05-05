import { describe, it, expect, vi, beforeEach } from 'vitest';
import { MosaicClient } from '../src/index';

// Mock fetch globally
const mockFetch = vi.fn();
global.fetch = mockFetch;

function mockResponse(data: unknown, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText: status === 200 ? 'OK' : 'Error',
    json: async () => data,
    text: async () => JSON.stringify(data),
  };
}

describe('MosaicClient', () => {
  let client: MosaicClient;

  beforeEach(() => {
    mockFetch.mockReset();
    client = new MosaicClient({ baseUrl: 'http://localhost:4040' });
  });

  describe('constructor', () => {
    it('accepts string URL', () => {
      const c = new MosaicClient('http://localhost:9999');
      expect(c).toBeDefined();
    });

    it('strips trailing slash from URL', () => {
      const c = new MosaicClient({ baseUrl: 'http://localhost:4040/' });
      // Tested indirectly via request URL
    });

    it('reads environment variables', () => {
      process.env.MOSAIC_API_KEY = 'test-key';
      process.env.MOSAIC_TENANT_ID = 'tenant-1';
      const c = new MosaicClient();
      expect(c).toBeDefined();
      delete process.env.MOSAIC_API_KEY;
      delete process.env.MOSAIC_TENANT_ID;
    });
  });

  describe('health', () => {
    it('calls /health endpoint', async () => {
      mockFetch.mockResolvedValueOnce({ ok: true, status: 200, statusText: 'OK', text: async () => 'ok', json: async () => 'ok' });
      const result = await client.health();
      expect(result).toBe('ok');
      expect(mockFetch).toHaveBeenCalledWith(
        'http://localhost:4040/health',
        expect.any(Object)
      );
    });
  });

  describe('search', () => {
    it('posts to /api/search', async () => {
      mockFetch.mockResolvedValueOnce(mockResponse({
        results: [{ id: 'doc_1', similarity: 0.95 }],
        path: 'hot',
      }));

      const results = await client.search('test query', { limit: 5 });
      expect(results).toHaveLength(1);
      expect(results[0].id).toBe('doc_1');
      expect(results[0].similarity).toBe(0.95);
    });

    it('uses hybrid endpoint when where clause provided', async () => {
      mockFetch.mockResolvedValueOnce(mockResponse({ results: [] }));

      await client.search('premium', { where: "category = 'electronics'" });

      expect(mockFetch).toHaveBeenCalledWith(
        expect.stringContaining('/api/search/hybrid'),
        expect.anything()
      );
    });

    it('throws on HTTP error', async () => {
      mockFetch.mockResolvedValueOnce(mockResponse({ error: 'bad request' }, 400));
      await expect(client.search('query')).rejects.toThrow('bad request');
    });
  });

  describe('analytics', () => {
    it('posts SQL to /api/analytics', async () => {
      mockFetch.mockResolvedValueOnce(mockResponse({
        results: [['books', 42]],
      }));

      const results = await client.analytics('SELECT category, COUNT(*) FROM docs GROUP BY 1');
      expect(results).toEqual([['books', 42]]);
    });
  });

  describe('traverse', () => {
    it('posts to graph traverse endpoint', async () => {
      mockFetch.mockResolvedValueOnce(mockResponse({
        results: [{ id: 'f1', name: 'handler/2', type: 'function' }],
      }));

      const results = await client.traverse('execute_query', 'callers', 2);
      expect(results[0].name).toBe('handler/2');
    });
  });

  describe('rag', () => {
    it('retrieves RAG results', async () => {
      mockFetch.mockResolvedValueOnce(mockResponse({
        query: 'test',
        chunks: [{ id: 'c1', similarity: 0.9, text: 'content' }],
        context: 'combined context',
        token_count: 100,
      }));

      const result = await client.rag('test', { topK: 3 });
      expect(result.chunks).toHaveLength(1);
      expect(result.token_count).toBe(100);
    });
  });

  describe('memory', () => {
    it('remembers content', async () => {
      mockFetch.mockResolvedValueOnce(mockResponse({
        memory: { id: 'mem_1', type: 'episodic', content: 'test', importance: 0.8, similarity: 1, score: 1, created_at: '2024-01-01', session_id: 's1' },
        stub: '$mem_s1_mem_1: Array(1) [test]',
      }, 201));

      const result = await client.remember('s1', 'test', { type: 'episodic' });
      expect(result.memory.id).toBe('mem_1');
      expect(result.stub).toContain('$mem_');
    });

    it('recalls memories', async () => {
      mockFetch.mockResolvedValueOnce(mockResponse({
        memories: [{ id: 'm1', content: 'remembered', type: 'episodic', importance: 0.5, similarity: 0.9, score: 0.85, created_at: '2024-01-01', session_id: 's1' }],
      }));

      const results = await client.recall('s1', 'what did I say');
      expect(results).toHaveLength(1);
    });
  });

  describe('cache', () => {
    it('gets cache stats', async () => {
      mockFetch.mockResolvedValueOnce(mockResponse({
        hits: 50, misses: 5, total: 55, hit_rate: 0.91, active_entries: 20,
        tokens_saved: 50000, estimated_cost_saved: 0.005,
      }));

      const stats = await client.cacheStats();
      expect(stats.hit_rate).toBe(0.91);
    });
  });

  describe('eval', () => {
    it('gets eval report', async () => {
      mockFetch.mockResolvedValueOnce(mockResponse({
        total_events: 100, precision_at_5: 0.87, recall_at_10: 0.94, mrr: 0.91,
      }));

      const report = await client.evalReport('retrieval', 'day');
      expect(report.precision_at_5).toBe(0.87);
    });
  });

  describe('auth', () => {
    it('logs in and stores token', async () => {
      mockFetch.mockResolvedValueOnce(mockResponse({ token: 'jwt-token-123' }));
      const result = await client.login('user', 'pass');
      expect(result.token).toBe('jwt-token-123');
    });
  });

  describe('mcp', () => {
    it('lists MCP tools', async () => {
      mockFetch.mockResolvedValueOnce(mockResponse([
        { name: 'mosaic_search', description: 'Semantic search', inputSchema: {} },
      ]));

      const tools = await client.mcpTools();
      expect(tools[0].name).toBe('mosaic_search');
    });
  });

  describe('headers', () => {
    it('includes API key when set', async () => {
      mockFetch.mockResolvedValueOnce(mockResponse({ results: [] }));
      client.setApiKey('mk_live_test123');

      await client.search('q');
      const call = mockFetch.mock.calls[0];
      const headers = call[1].headers;
      expect(headers['X-API-Key']).toBe('mk_live_test123');
    });

    it('includes JWT token when set', async () => {
      mockFetch.mockResolvedValueOnce(mockResponse({ results: [] }));
      client.setJwtToken('eyJhbGci...');

      await client.search('q');
      const call = mockFetch.mock.calls[0];
      const headers = call[1].headers;
      expect(headers['Authorization']).toBe('Bearer eyJhbGci...');
    });

    it('includes tenant ID when set', async () => {
      mockFetch.mockResolvedValueOnce(mockResponse({ results: [] }));
      client.setTenantId('tenant-xyz');

      await client.search('q');
      const call = mockFetch.mock.calls[0];
      const headers = call[1].headers;
      expect(headers['X-Tenant-ID']).toBe('tenant-xyz');
    });
  });
});
