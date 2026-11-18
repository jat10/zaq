defmodule Zaq.Channels.FileRequirements do
  @moduledoc """
  Resolved constraints for attachment delivery through one selected connection.

  Limits are positive byte/count values or explicit `:not_applicable` values.
  Missing values remain `:unresolved` and fail validation before acquisition.
  Explicitly inapplicable ceilings are valid for either transfer mode.
  The transfer mode describes transport capabilities; ZAQ owns delivery policy.
  """

  alias Zaq.Channels.DeliveryError

  @enforce_keys [:transfer_mode, :max_files_per_message]
  defstruct [
    :transfer_mode,
    :max_files_per_message,
    max_file_bytes: :unresolved,
    max_attachment_bytes_per_message: :unresolved,
    max_encoded_message_bytes: :unresolved,
    max_upload_request_bytes: :unresolved,
    supports_threads: false,
    supports_attachment_edits: false
  ]

  @type limit :: pos_integer() | :not_applicable | :unresolved
  @type t :: %__MODULE__{
          transfer_mode: :upload_then_publish | :send_with_files,
          max_files_per_message: pos_integer(),
          max_file_bytes: limit(),
          max_attachment_bytes_per_message: limit(),
          max_encoded_message_bytes: limit(),
          max_upload_request_bytes: limit(),
          supports_threads: boolean(),
          supports_attachment_edits: boolean()
        }

  @limits [
    :max_file_bytes,
    :max_attachment_bytes_per_message,
    :max_encoded_message_bytes,
    :max_upload_request_bytes
  ]

  @doc "Rejects unresolved or malformed constraints before file acquisition."
  @spec validate(t()) :: :ok | {:error, DeliveryError.t()}
  def validate(%__MODULE__{} = requirements) do
    valid? =
      requirements.transfer_mode in [:upload_then_publish, :send_with_files] and
        positive?(requirements.max_files_per_message) and
        is_boolean(requirements.supports_threads) and
        is_boolean(requirements.supports_attachment_edits) and
        Enum.all?(@limits, &resolved?(Map.fetch!(requirements, &1)))

    if valid?, do: :ok, else: invalid_requirements()
  end

  def validate(_requirements), do: invalid_requirements()

  defp resolved?(:not_applicable), do: true
  defp resolved?(value), do: positive?(value)
  defp positive?(value), do: is_integer(value) and value > 0

  defp invalid_requirements do
    {:error,
     %DeliveryError{
       reason: :invalid_file_requirements,
       message: "Attachment delivery limits are missing or invalid for this connector.",
       stage: :configuration,
       delivery: :not_sent
     }}
  end
end
