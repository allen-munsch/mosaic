defmodule Mosaic.WorkerPool do
  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)
    worker = Keyword.fetch!(opts, :worker)
    size = Keyword.get(opts, :size, 5)

    :poolboy.child_spec(name, [name: {:local, name}, worker_module: worker, size: size, max_overflow: 2], [])
  end

  def transaction(pool, fun, timeout \\ 5000) do
    :poolboy.transaction(pool, fun, timeout)
  end
end