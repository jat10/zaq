defmodule Zaq.Test.FileDeliveryAdapter do
  @moduledoc false

  alias Jido.Chat.Mattermost.Adapter
  alias Jido.Chat.Response

  def get(:zaq, :channels, _default, opts),
    do: %{
      mattermost: %{
        bridge: Zaq.Channels.JidoChatBridge,
        adapter: Keyword.get(opts, :fixture_adapter, __MODULE__)
      }
    }

  def get(_app, _key, default, _opts), do: default

  def get(:zaq, :channels, _default), do: %{mattermost: %{adapter: __MODULE__}}
  def get(_app, _key, default), do: default

  defdelegate channel_type(), to: Jido.Chat.Mattermost.Adapter

  def capabilities do
    Adapter.capabilities()
    |> Map.merge(%{uploaded_files: :native, edit_attachments: :native})
  end

  def file_requirements(opts) do
    send(owner(opts), :adapter_requirements)

    {:ok,
     %{
       max_files_per_post: 2,
       max_file_size: :unresolved,
       max_upload_request_size: :not_applicable,
       max_encoded_message_bytes: :not_applicable
     }}
  end

  def prepare_upload(channel, files, _opts) do
    encoded = :erlang.term_to_binary({channel, files})
    {:ok, %{size_bytes: byte_size(encoded), body: encoded, files: files}}
  end

  def upload_prepared(prepared, opts) do
    send(owner(opts), {:adapter_upload, prepared})

    case opts[:url] do
      "uncertain-first" ->
        {:ok, %{files: Enum.map(prepared.files, &%{id: &1.filename})}}

      "abort-late-upload" ->
        if Enum.any?(prepared.files, &(&1.filename == "reject.dat")),
          do: {:error, :upload_outcome_unknown},
          else:
            {:ok,
             %{
               files:
                 Enum.with_index(prepared.files, fn _, index -> %{id: "uploaded-#{index}"} end)
             }}

      "partial" ->
        {:error, {:partial_upload, %{files: [%{input_index: 1, id: "known-second"}]}}}

      "ambiguous" ->
        {:ok, %{files: [%{id: "unknown-input"}]}}

      _ ->
        {:ok,
         %{files: Enum.with_index(prepared.files, fn _, index -> %{id: "uploaded-#{index}"} end)}}
    end
  end

  def send_message(channel, body, opts) do
    send(owner(opts), {:adapter_send, channel, body, opts})

    if opts[:url] == "uncertain-first" and %{id: "first.dat"} in (opts[:uploaded_files] || []) do
      {:error, :timeout}
    else
      {:ok,
       Response.new(%{
         external_message_id: "sent-#{System.unique_integer([:positive])}",
         external_room_id: channel
       })}
    end
  end

  def edit_message(channel, id, body, opts) do
    send(owner(opts), {:adapter_edit, channel, id, body, opts})

    {:ok,
     Response.new(%{
       external_message_id: id,
       external_room_id: channel,
       status: :edited
     })}
  end

  def fetch_media(reference, opts) do
    send(owner(opts), {:adapter_fetch_media, reference})
    {:ok, "acquired bytes"}
  end

  defp owner(opts) do
    case opts[:token] do
      pid when is_pid(pid) -> pid
      encoded when is_binary(encoded) -> encoded |> String.to_charlist() |> :erlang.list_to_pid()
    end
  end
end

defmodule Zaq.Test.TextDeliveryAdapter do
  @moduledoc false
  defdelegate channel_type(), to: Jido.Chat.Mattermost.Adapter
  defdelegate capabilities(), to: Jido.Chat.Mattermost.Adapter
  defdelegate send_message(channel, body, opts), to: Zaq.Test.FileDeliveryAdapter
  defdelegate edit_message(channel, id, body, opts), to: Zaq.Test.FileDeliveryAdapter
end
