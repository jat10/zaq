defmodule Zaq.Ingestion.PostProcessingTest do
  use Zaq.DataCase, async: true
  alias Zaq.Ingestion.{Document, PostProcessing}
  alias Zaq.Ingestion.PostProcessing.{Request, Worker}

  defmodule Processor do
    @behaviour Zaq.Ingestion.PostProcessing.Processor
    def eligible?(_resource, context), do: context[:enabled] == true

    def reserve(_resource, context),
      do: [%{request_key: "one", payload: %{"result" => context[:result] || "ok"}}]

    def perform(%{payload: %{"result" => "failure"}}, _opts), do: {:error, :provider_failed}
    def perform(_request, _opts), do: :ok
  end

  defmodule Config do
    def get(:zaq, :labeling_processor, _), do: Processor
  end

  defp resource do
    {:ok, document} = Document.create(%{source: Ecto.UUID.generate()})
    %{type: "document", id: document.id, document_id: document.id, generation: 0}
  end

  test "reservation and enqueue roll back together and repeated scheduling is idempotent" do
    resource = resource()

    assert {:error, :rollback} =
             Repo.transaction(fn ->
               assert {:ok, [_]} =
                        PostProcessing.schedule(resource, %{enabled: true}, config: Config)

               Repo.rollback(:rollback)
             end)

    assert Repo.aggregate(Request, :count) == 0
    assert {:ok, [request]} = PostProcessing.schedule(resource, %{enabled: true}, config: Config)
    assert {:ok, []} = PostProcessing.schedule(resource, %{enabled: true}, config: Config)

    assert %Oban.Job{args: %{"request_id" => id}} =
             Repo.get_by!(Oban.Job, args: %{"request_id" => request.id})

    assert id == request.id
  end

  test "infrastructure retry recovers a running reservation" do
    assert {:ok, [request]} =
             PostProcessing.schedule(resource(), %{enabled: true}, config: Config)

    Repo.update!(Ecto.Changeset.change(request, status: "running"))
    job = %Oban.Job{args: %{"request_id" => request.id}, attempt: 1, max_attempts: 3}
    assert :ok = Worker.perform(job, config: Config)
    assert Repo.reload!(request).status == "running"
    assert :ok = Worker.perform(%{job | attempt: 2}, config: Config)
    assert Repo.reload!(request).status == "completed"
  end

  test "terminal provider failure is persisted and duplicate delivery does nothing" do
    assert {:ok, [request]} =
             PostProcessing.schedule(resource(), %{enabled: true, result: "failure"},
               config: Config
             )

    job = %Oban.Job{args: %{"request_id" => request.id}, attempt: 1, max_attempts: 3}
    assert :ok = Worker.perform(job, config: Config)
    assert %{status: "failed", error: "provider_failed"} = Repo.reload!(request)
    assert :ok = Worker.perform(job, config: Config)
    assert Repo.reload!(request).status == "failed"
  end

  test "skip and stale generation never enqueue; unknown processor keys cannot select modules" do
    resource = resource()
    assert {:ok, []} = PostProcessing.schedule(resource, %{}, config: Config)

    assert {:error, :stale_generation} =
             PostProcessing.schedule(%{resource | generation: 1}, %{enabled: true},
               config: Config
             )

    assert {:error, :unknown_processor} =
             PostProcessing.processor("Elixir.System", config: Config)
  end
end
