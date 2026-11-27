defmodule :atomvm do
  @moduledoc """
  Test-only stand-in for AtomVM's `atomvm` module.

  Only compiled in the `:test` environment (`elixirc_paths(:test)`).  Provides
  `read_priv/2` backed by a public ETS table so tests can register mock priv
  files per `{app, path}` without touching a real AtomVM build.

      :atomvm.put_priv(:my_app, "index.html", "<html></html>")

  The ETS table is owned by a long-lived unlinked process so entries survive
  the test process that registered them (use `reset_priv/0` to clean up).
  """

  @table :atomvm_priv_mock

  @doc """
  Mimics `atomvm:read_priv/2`: returns the registered binary or `:undefined`.
  """
  def read_priv(app, path) do
    case :ets.lookup(ensure_table(), {app, normalize(path)}) do
      [{_key, data}] -> data
      [] -> :undefined
    end
  end

  @doc """
  Registers a mock priv file.  `data` must be a binary (or `:undefined` to
  emulate a missing file).
  """
  def put_priv(app, path, data) when is_binary(data) or data == :undefined do
    :ets.insert(ensure_table(), {{app, normalize(path)}, data})
    :ok
  end

  @doc """
  Removes every registered mock priv file.
  """
  def reset_priv do
    :ets.delete_all_objects(ensure_table())
    :ok
  end

  defp normalize(path), do: to_string(path)

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> start_owner()
      _tid -> @table
    end
  end

  defp start_owner do
    parent = self()

    spawn(fn ->
      try do
        :ets.new(@table, [:named_table, :public, :set])
      catch
        # Another process won the race; the table already exists.
        :error, :badarg -> @table
      end

      send(parent, {:atomvm_priv_table, @table})

      receive do
        _ -> :ok
      end
    end)

    receive do
      {:atomvm_priv_table, @table} -> @table
    after
      1_000 -> @table
    end
  end
end
