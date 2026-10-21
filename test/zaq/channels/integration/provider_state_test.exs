defmodule Zaq.Channels.Integration.ProviderStateTest do
  use ExUnit.Case, async: true
  alias Zaq.TestSupport.Channels.Integration.ProviderState

  test "terminal scripts do not consume incidental operations and fail on exhaustion" do
    pid =
      start_supervised!({ProviderState, provider: :mattermost, owner: self(), scope: "script"})

    assert :ok = ProviderState.bind(pid, 123)

    assert :ok =
             ProviderState.script(pid, %{
               operation: :send,
               match: %{text: "Final"},
               results: [{:error, :offline}]
             })

    assert {:ok, _} =
             ProviderState.attempt(pid, %{
               operation: :typing,
               channel_id: "room",
               native_payload: %{}
             })

    assert {:ok, _} =
             ProviderState.attempt(pid, %{
               operation: :send,
               channel_id: "room",
               text: "Working",
               native_payload: %{}
             })

    assert {:error, :offline} =
             ProviderState.attempt(pid, %{
               operation: :send,
               channel_id: "room",
               text: "Final",
               native_payload: %{}
             })

    assert {:error, :script_exhausted} =
             ProviderState.attempt(pid, %{
               operation: :send,
               channel_id: "room",
               text: "Final",
               native_payload: %{}
             })

    assert Enum.map(ProviderState.deliveries(pid), & &1.sequence) == [1, 2, 3, 4]
    assert Enum.all?(ProviderState.deliveries(pid), &(&1.channel_config_id == 123))
  end

  test "invalid script shape is rejected without changing future results" do
    pid = start_supervised!({ProviderState, provider: :telegram, owner: self(), scope: "invalid"})
    assert {:error, :invalid_script} = ProviderState.script(pid, %{operation: :send})
    assert ProviderState.deliveries(pid) == []
  end
end
