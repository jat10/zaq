defmodule Zaq.Channels.Delivery.Error do
  @moduledoc """
  Channel-local failure facts with private transport causes.

  A timeout or unknown provider outcome is unconfirmed, never proof of rejection.
  `cause` retains diagnostics for the execution owner; only `safe_facts/1` may be
  included in grouped Engine evidence. These facts do not instruct a retry.
  """

  @enforce_keys [:stage, :outcome, :reason]
  @derive {Inspect, only: [:stage, :outcome, :reason, :provider_code]}
  defstruct [:stage, :outcome, :reason, :provider_code, :cause]

  @type stage :: :configuration | :preparation | :upload | :publication
  @type outcome :: :failed | :unconfirmed
  @type reason ::
          :rejected
          | :missing_configuration
          | :unsupported_provider
          | :invalid_plan
          | :invalid_attachment
          | :content_unavailable
          | :preparation_failed
          | :size_limit
          | :dependency_failed
          | :aborted
          | :timeout
          | :unknown
  @type t :: %__MODULE__{
          stage: stage(),
          outcome: outcome(),
          reason: reason(),
          provider_code: 0..999 | nil,
          cause: term()
        }

  @stages [:configuration, :preparation, :upload, :publication]
  @definite_reasons [
    :rejected,
    :missing_configuration,
    :unsupported_provider,
    :invalid_plan,
    :invalid_attachment,
    :content_unavailable,
    :preparation_failed,
    :size_limit,
    :dependency_failed,
    :aborted
  ]

  @doc "Projects allowlisted facts, rejecting malformed certainty or provider codes."
  @spec safe_facts(t()) :: {:ok, map()} | {:error, :invalid_delivery_error}
  def safe_facts(%__MODULE__{stage: stage} = error) when stage in @stages do
    if valid_certainty?(error) do
      facts = Map.take(error, [:stage, :outcome, :reason])

      case error.provider_code do
        nil ->
          {:ok, facts}

        code when is_integer(code) and code in 0..999 ->
          {:ok, Map.put(facts, :provider_code, code)}

        _ ->
          {:error, :invalid_delivery_error}
      end
    else
      {:error, :invalid_delivery_error}
    end
  end

  def safe_facts(_error), do: {:error, :invalid_delivery_error}

  defp valid_certainty?(%__MODULE__{outcome: :failed, reason: reason})
       when reason in @definite_reasons,
       do: true

  defp valid_certainty?(%__MODULE__{stage: stage, outcome: :unconfirmed, reason: reason})
       when stage in [:upload, :publication] and reason in [:timeout, :unknown],
       do: true

  defp valid_certainty?(_error), do: false
end
