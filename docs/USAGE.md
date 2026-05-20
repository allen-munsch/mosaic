## Index a Document

```bash
curl -X POST http://localhost:4040/api/index \
  -H "Content-Type: application/json" \
  -d '{"id": "doc1", "text": "Elixir is a functional programming language"}'
```

**Response:**

```json
{"id":"doc1","status":"indexed","shard_id":"shard_1764245723727_807"}
```

---

## Search

```bash
curl -X POST http://localhost:4040/api/search \
  -H "Content-Type: application/json" \
  -d '{"query": "functional programming"}'
```

**Response:**

```json
{
  "results": [
    {
      "id": "doc1",
      "text": "Elixir is a functional programming language",
      "metadata": "{}",
      "shard_id": "test_shard_001",
      "similarity": 0.16316609851841604
    }
  ]
}
```

---

## Query via IEx

### Heartbeat logs

```
[info] Heartbeat: health check completed, status: healthy
```

### Query documents

```elixir
iex> Mosaic.FederatedQuery.execute(
...>   "SELECT id, text FROM documents WHERE text LIKE ?",
...>   ["%Elixir%"]
...> )
[["doc1", "Elixir is a functional programming language"]]
```

### Query with metadata

```elixir
iex> Mosaic.FederatedQuery.execute_with_metadata("SELECT count(*) FROM documents")
[%{status: :ok, rows: [[1]], shard_id: "test_shard_001"}]
```