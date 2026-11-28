defmodule Zaq.ConnectorConfig.FileFailurePolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Zaq.ConnectorConfig.FileSettings

  test "selected connection policy preserves literal false and the default" do
    assert {:ok, :continue} = FileSettings.failure_policy(%{})

    assert {:ok, :abort} =
             %{settings: %{"file_delivery" => %{"send_on_file_failure" => false}}}
             |> FileSettings.from_connection()
             |> FileSettings.failure_policy()

    assert {:ok, :continue} = FileSettings.failure_policy(%{"send_on_file_failure" => true})
  end

  property "only literal booleans choose a failure policy" do
    check all(value <- term()) do
      case value do
        true ->
          assert {:ok, :continue} =
                   FileSettings.failure_policy(%{"send_on_file_failure" => value})

        false ->
          assert {:ok, :abort} = FileSettings.failure_policy(%{"send_on_file_failure" => value})

        _ ->
          assert {:error, :invalid_failure_policy} =
                   FileSettings.failure_policy(%{"send_on_file_failure" => value})
      end
    end
  end
end
