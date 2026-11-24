defmodule Zaq.ConnectorConfig.SmtpSettings do
  @moduledoc "Pure SMTP settings access shared by persistence, presentation and transport."

  @setting_atom_keys %{
    "relay" => :relay,
    "port" => :port,
    "transport_mode" => :transport_mode,
    "tls" => :tls,
    "tls_verify" => :tls_verify,
    "ca_cert_path" => :ca_cert_path,
    "username" => :username,
    "password" => :password,
    "from_email" => :from_email,
    "from_name" => :from_name,
    "max_encoded_message_bytes" => :max_encoded_message_bytes,
    "max_attachments_per_message" => :max_attachments_per_message,
    "max_files_per_message" => :max_files_per_message
  }

  @doc "Looks up a SMTP settings key by string name, falling back to its atom equivalent."
  def map_get(map, "max_attachments_per_message") when is_map(map) do
    Map.get(
      map,
      "max_attachments_per_message",
      Map.get(
        map,
        :max_attachments_per_message,
        Map.get(map, "max_files_per_message", Map.get(map, :max_files_per_message))
      )
    )
  end

  def map_get(map, key) when is_map(map) do
    atom_key = Map.get(@setting_atom_keys, key)
    if atom_key, do: Map.get(map, key, Map.get(map, atom_key)), else: Map.get(map, key)
  end

  @doc "Returns actionable errors for attachment limits at SMTP save boundaries."
  @spec delivery_errors(map(), boolean()) :: [{String.t(), String.t()}]
  def delivery_errors(settings, required?) do
    Enum.flat_map(["max_encoded_message_bytes", "max_attachments_per_message"], fn key ->
      case map_get(settings, key) do
        nil when not required? ->
          []

        value when is_integer(value) and value > 0 ->
          []

        _ ->
          [{key, "must be a positive integer; configure SMTP attachment limits before enabling"}]
      end
    end)
  end

  @doc "Converts validated decimal MB to bytes, using 1 MB = 1,000,000 bytes."
  @spec message_bytes(Decimal.t() | nil) :: pos_integer() | nil
  def message_bytes(nil), do: nil

  def message_bytes(%Decimal{} = megabytes),
    do: megabytes |> scaled_message_bytes() |> Decimal.to_integer()

  @doc "Checks whole-byte precision without applying Decimal's arithmetic rounding context."
  @spec whole_message_bytes?(Decimal.t()) :: boolean()
  def whole_message_bytes?(%Decimal{} = megabytes),
    do: megabytes |> scaled_message_bytes() |> Decimal.integer?()

  @doc "Projects persisted bytes into an exact decimal MB form value."
  @spec message_megabytes(pos_integer() | nil) :: Decimal.t() | nil
  def message_megabytes(bytes) when is_integer(bytes) and bytes > 0,
    do: Decimal.new(1, bytes, -6)

  def message_megabytes(_bytes), do: nil

  defp scaled_message_bytes(%Decimal{sign: sign, coef: coefficient, exp: exponent}),
    do: Decimal.new(sign, coefficient, exponent + 6)
end
