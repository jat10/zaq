defmodule Zaq.Channels.Delivery.ErrorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.Delivery.Error

  test "provider codes are bounded and private causes are excluded" do
    error = %Error{
      stage: :publication,
      outcome: :failed,
      reason: :rejected,
      provider_code: 403,
      cause: %{token: "private"}
    }

    assert {:ok, %{stage: :publication, outcome: :failed, reason: :rejected, provider_code: 403}} =
             Error.safe_facts(error)

    for code <- [-1, 1_000, "403", %{body: "private"}] do
      assert {:error, :invalid_delivery_error} = Error.safe_facts(%{error | provider_code: code})
    end
  end

  test "local configuration and preparation failures cannot imply uncertain provider acceptance" do
    for stage <- [:configuration, :preparation] do
      assert {:error, :invalid_delivery_error} =
               Error.safe_facts(%Error{stage: stage, outcome: :unconfirmed, reason: :timeout})
    end
  end

  property "unknown transport errors never become definite rejection" do
    check all(cause <- term()) do
      error = %Error{stage: :publication, outcome: :unconfirmed, reason: :unknown, cause: cause}
      assert {:ok, %{outcome: :unconfirmed, reason: :unknown}} = Error.safe_facts(error)
      assert {:error, :invalid_delivery_error} = Error.safe_facts(%{error | outcome: :failed})
    end
  end
end
