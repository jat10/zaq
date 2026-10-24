defmodule Zaq.TestSupport.ModelCatalogFixture do
  @moduledoc """
  Selects a small valid base catalog for synchronous model-overlay tests.

  The real loader still parses and validates the snapshot. This changes the
  global snapshot source, so callers must be synchronous and restore any catalog
  they load. The source setting and temporary file are restored on exit.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  def use_minimal_source! do
    {:ok, provider} = LLMDB.provider(:openai)
    {:ok, model} = LLMDB.model(:openai, "gpt-4.1-mini")
    path = Path.join(System.tmp_dir!(), "zaq-catalog-#{Ecto.UUID.generate()}.json")
    previous = Application.fetch_env(:llm_db, :snapshot_source)

    on_exit(fn ->
      case previous do
        {:ok, source} -> Application.put_env(:llm_db, :snapshot_source, source)
        :error -> Application.delete_env(:llm_db, :snapshot_source)
      end

      File.rm(path)
    end)

    LLMDB.Snapshot.write!(
      path,
      LLMDB.Snapshot.from_engine_snapshot(%{
        version: 2,
        generated_at: DateTime.to_iso8601(DateTime.utc_now()),
        providers: %{
          "openai" => Map.put(Map.from_struct(provider), :models, %{model.id => model})
        }
      })
    )

    Application.put_env(:llm_db, :snapshot_source, {:file, path})
  end
end
