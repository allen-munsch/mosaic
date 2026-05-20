defmodule Mosaic.TestHelpers do
  alias Mosaic.{ConnectionPool, Config, DB}

  @doc "Setup isolated test environment with fresh routing DB"
  def setup_integration_test(_context) do
    temp_dir = Path.join(System.tmp_dir!(), "mosaic_test_#{System.unique_integer([:positive])}")
    storage_path = Path.join(temp_dir, "shards")
    routing_path = Path.join(temp_dir, "routing")
    routing_db = Path.join(routing_path, "index.db")

    File.mkdir_p!(storage_path)
    File.mkdir_p!(routing_path)

    Config.update_setting(:storage_path, storage_path)
    Config.update_setting(:routing_db_path, routing_db)

    # Reset Indexer's active shard to force new shard creation
    :ets.insert(:indexer_state, {:active_shard, nil, nil, 0})

    Mosaic.ShardRouter.reset_state()

    on_exit_fun = fn -> File.rm_rf!(temp_dir) end
    {:ok, %{temp_dir: temp_dir, on_exit: on_exit_fun}}
  end

  @doc "Index document and return connection for direct verification"
  def index_and_connect(doc_id, text, metadata \\ %{})
  def index_and_connect(doc_id, text, metadata) do
    {:ok, result} = Mosaic.Indexer.index_document(doc_id, text, metadata)
    {:ok, conn} = Mosaic.ConnectionPool.checkout(result.shard_path)
    {result, conn}
  end

  @doc "Verify document exists in shard"
  def assert_document_indexed(conn, doc_id)
  def assert_document_indexed(conn, doc_id) do
    {:ok, [[count]]} = DB.query(conn, "SELECT COUNT(*) FROM documents WHERE id = ?", [doc_id])
    count > 0
  end

  @doc "Verify chunks exist at all levels"
  def assert_chunks_created(conn, doc_id)
  def assert_chunks_created(conn, doc_id) do
    {:ok, rows} = DB.query(conn, "SELECT DISTINCT level FROM chunks WHERE doc_id = ?", [doc_id])
    levels = Enum.map(rows, fn [l] -> l end) |> Enum.sort()
    levels == ["document", "paragraph", "sentence"]
  end

  @doc "Verify embeddings exist for all chunks"
  def assert_embeddings_created(conn, doc_id)
  def assert_embeddings_created(conn, doc_id) do
    {:ok, [[chunk_count]]} = DB.query(conn, "SELECT COUNT(*) FROM chunks WHERE doc_id = ?", [doc_id])
    {:ok, [[vec_count]]} = DB.query(conn, "SELECT COUNT(*) FROM vec_chunks WHERE id IN (SELECT id FROM chunks WHERE doc_id = ?)", [doc_id])
    chunk_count > 0 and chunk_count == vec_count
  end

  @doc "Execute query and verify results exist"
  def assert_query_returns_results(query_text, opts \\ [])
  def assert_query_returns_results(query_text, opts) do
    case Mosaic.QueryEngine.execute_query(query_text, opts) do
      {:ok, [_ | _] = results} -> results
      {:ok, []} -> raise "Query returned no results: #{query_text}"
      {:error, err} -> raise "Query failed: #{inspect(err)}"
    end
  end

  @doc "Cleanup shard connection"
  def cleanup_conn(shard_path, conn) do
    ConnectionPool.checkin(shard_path, conn)
  end
end

defmodule Mosaic.CacheTestHelpers do
  defmacro define_cache_tests do
    quote do
      test "get miss", %{cache_module: mod, cache_name: name} do
        assert mod.get("nonexistent", name) == :miss
      end
      test "put/get roundtrip", %{cache_module: mod, cache_name: name} do
        assert mod.put("k", "v", 300, name) == :ok
        assert mod.get("k", name) == {:ok, "v"}
      end
      test "delete", %{cache_module: mod, cache_name: name} do
        mod.put("k", "v", 300, name)
        mod.delete("k", name)
        assert mod.get("k", name) == :miss
      end
      test "clear", %{cache_module: mod, cache_name: name} do
        mod.put("a", 1, 300, name)
        mod.put("b", 2, 300, name)
        mod.clear(name)
        assert mod.get("a", name) == :miss
      end
    end
  end
end