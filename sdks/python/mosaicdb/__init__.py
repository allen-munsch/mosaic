"""
MosaicDB Python SDK — Federated Semantic Search & Code Graph Client.

Usage:
    from mosaicdb import MosaicClient

    client = MosaicClient("http://localhost:4040")

    # Search
    results = client.search("error handling in auth", limit=5)

    # Hybrid search (vector + SQL filter)
    results = client.search("premium quality", where="category = 'electronics'", limit=10)

    # Graph traversal
    callers = client.traverse("execute_query", relation="callers", depth=2)

    # RAG retrieval
    chunks = client.rag("What is the auth flow?", top_k=5)

    # DuckDB analytics
    rows = client.analytics("SELECT category, COUNT(*) FROM documents GROUP BY 1")

    # Index code
    stats = client.ingest_code("./src")

    # Index documents
    stats = client.ingest_docs("./kb/articles/")

    # Graph report
    report = client.graph_report()
"""

from __future__ import annotations

import json
import os
from typing import Any, Optional, List, Dict

import httpx


class MosaicClient:
    """Client for the MosaicDB HTTP API."""

    def __init__(
        self,
        base_url: str = "http://localhost:4040",
        api_key: Optional[str] = None,
        jwt_token: Optional[str] = None,
        tenant_id: Optional[str] = None,
        timeout: float = 30.0,
    ):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key or os.environ.get("MOSAIC_API_KEY")
        self.jwt_token = jwt_token or os.environ.get("MOSAIC_JWT_TOKEN")
        self.tenant_id = tenant_id or os.environ.get("MOSAIC_TENANT_ID", "default")
        self.timeout = timeout
        self._client = httpx.Client(timeout=timeout)

    def _headers(self) -> dict:
        h = {"Content-Type": "application/json"}
        if self.api_key:
            h["X-API-Key"] = self.api_key
        if self.jwt_token:
            h["Authorization"] = f"Bearer {self.jwt_token}"
        if self.tenant_id:
            h["X-Tenant-ID"] = self.tenant_id
        return h

    def _post(self, path: str, data: dict) -> dict:
        resp = self._client.post(
            f"{self.base_url}{path}", json=data, headers=self._headers()
        )
        resp.raise_for_status()
        return resp.json()

    def _get(self, path: str) -> dict:
        resp = self._client.get(f"{self.base_url}{path}", headers=self._headers())
        resp.raise_for_status()
        return resp.json()

    # ── Search ─────────────────────────────────────────────

    def search(
        self,
        query: str,
        limit: int = 20,
        min_similarity: float = 0.1,
        where: Optional[str] = None,
        hybrid: bool = False,
    ) -> List[Dict[str, Any]]:
        """Semantic (or hybrid) search across indexed documents and code."""
        endpoint = "/api/search/hybrid" if (hybrid or where) else "/api/search"
        payload = {"query": query, "limit": limit, "min_similarity": min_similarity}
        if where:
            payload["where"] = where
        return self._post(endpoint, payload)

    def analytics(self, sql: str) -> List[List[Any]]:
        """Execute DuckDB SQL analytics across federated shards."""
        return self._post("/api/analytics", {"sql": sql})

    # ── Graph ──────────────────────────────────────────────

    def traverse(
        self,
        node: str,
        relation: str = "callers",
        depth: int = 1,
        limit: int = 50,
    ) -> Dict[str, Any]:
        """Navigate the code graph from a node."""
        return self._post("/api/graph/traverse", {
            "node": node,
            "relation": relation,
            "depth": depth,
            "limit": limit,
        })

    def graph_report(
        self,
        god_nodes: int = 10,
        bridge_nodes: int = 10,
    ) -> Dict[str, Any]:
        """Generate a comprehensive graph analysis report."""
        return self._post("/api/graph/report", {
            "god_nodes": god_nodes,
            "bridge_nodes": bridge_nodes,
        })

    # ── Ingestion ──────────────────────────────────────────

    def ingest_code(
        self,
        path: str,
        language: Optional[str] = None,
        incremental: bool = True,
    ) -> Dict[str, Any]:
        """Parse and index a codebase into the property graph."""
        return self._post("/api/ingest/code", {
            "path": path,
            "language": language,
            "incremental": incremental,
        })

    def ingest_docs(
        self,
        path: str,
        chunk_strategy: str = "paragraph",
        chunk_size: int = 512,
        chunk_overlap: int = 64,
    ) -> Dict[str, Any]:
        """Ingest documents (PDF, DOCX, MD, TXT, HTML) with chunking."""
        return self._post("/api/ingest/docs", {
            "path": path,
            "chunk_strategy": chunk_strategy,
            "chunk_size": chunk_size,
            "chunk_overlap": chunk_overlap,
        })

    def ingest_s3(
        self,
        bucket: str,
        prefix: str,
        region: str = "us-east-1",
    ) -> Dict[str, Any]:
        """Ingest documents from an S3 bucket."""
        return self._post("/api/ingest/s3", {
            "bucket": bucket,
            "prefix": prefix,
            "region": region,
        })

    # ── RAG ────────────────────────────────────────────────

    def rag(
        self,
        query: str,
        top_k: int = 5,
        hybrid: bool = False,
        expand_context: bool = True,
    ) -> Dict[str, Any]:
        """Retrieve relevant chunks for RAG with assembled context."""
        endpoint = "/api/rag/hybrid" if hybrid else "/api/rag"
        return self._post(endpoint, {
            "query": query,
            "top_k": top_k,
            "expand_context": expand_context,
        })

    def rag_compressed(
        self, query: str, top_k: int = 10
    ) -> str:
        """Retrieve with handle compression — returns compact stubs."""
        result = self._post("/api/rag/compressed", {"query": query, "top_k": top_k})
        return result.get("stub", "")

    # ── Status & Health ────────────────────────────────────

    def health(self) -> Dict[str, Any]:
        """Health check."""
        return self._get("/health")

    def status(self) -> Dict[str, Any]:
        """Get full system status (shards, nodes, edges, handles)."""
        return self._get("/api/status")

    def stats(self) -> Dict[str, Any]:
        """Get indexing stats and shard topology."""
        return self._get("/api/stats")

    # ── Token Management ──────────────────────────────────

    def login(self, username: str, password: str) -> Dict[str, Any]:
        """Get a JWT token for the HTTP API."""
        result = self._post("/api/auth/login", {
            "username": username,
            "password": password,
        })
        if "token" in result:
            self.jwt_token = result["token"]
        return result

    def create_api_key(self, scopes: List[str]) -> Dict[str, Any]:
        """Create a new API key."""
        return self._post("/api/auth/keys", {"scopes": scopes})

    # ── MCP ────────────────────────────────────────────────

    def mcp_tools(self) -> List[Dict[str, Any]]:
        """List available MCP tools."""
        return self._post("/mcp", {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
            "params": {},
        })

    def mcp_call(self, tool: str, arguments: dict) -> Dict[str, Any]:
        """Call an MCP tool."""
        return self._post("/mcp", {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": tool, "arguments": arguments},
        })


class MosaicAsyncClient:
    """Async client for MosaicDB using httpx.AsyncClient."""

    def __init__(
        self,
        base_url: str = "http://localhost:4040",
        api_key: Optional[str] = None,
        jwt_token: Optional[str] = None,
        tenant_id: Optional[str] = None,
        timeout: float = 30.0,
    ):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key or os.environ.get("MOSAIC_API_KEY")
        self.jwt_token = jwt_token or os.environ.get("MOSAIC_JWT_TOKEN")
        self.tenant_id = tenant_id or os.environ.get("MOSAIC_TENANT_ID", "default")
        self.timeout = timeout
        self._client: Optional[httpx.AsyncClient] = None

    async def _get_client(self) -> httpx.AsyncClient:
        if self._client is None:
            self._client = httpx.AsyncClient(timeout=self.timeout)
        return self._client

    def _headers(self) -> dict:
        h = {"Content-Type": "application/json"}
        if self.api_key:
            h["X-API-Key"] = self.api_key
        if self.jwt_token:
            h["Authorization"] = f"Bearer {self.jwt_token}"
        if self.tenant_id:
            h["X-Tenant-ID"] = self.tenant_id
        return h

    async def search(
        self, query: str, limit: int = 20, where: Optional[str] = None
    ) -> List[Dict]:
        client = await self._get_client()
        endpoint = "/api/search/hybrid" if where else "/api/search"
        payload = {"query": query, "limit": limit}
        if where:
            payload["where"] = where
        resp = await client.post(
            f"{self.base_url}{endpoint}", json=payload, headers=self._headers()
        )
        resp.raise_for_status()
        return resp.json()

    async def close(self):
        if self._client:
            await self._client.aclose()
            self._client = None
