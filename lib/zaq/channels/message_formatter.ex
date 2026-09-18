defmodule Zaq.Channels.MessageFormatter do
  @moduledoc """
  Channel-aware outbound message formatting at the Channels API boundary.

  This module is a Channels concern and is applied by `Zaq.Channels.Api` before
  delegating to provider bridges (`send_reply/2`, `upsert_message/3`).

  Source message bodies are expected to be markdown. Per-provider output format
  is configured under `config :zaq, :channels` with `:message_format`:

      config :zaq, :channels, %{
        mattermost: %{bridge: Zaq.Channels.JidoChatBridge},
        email: %{bridge: Zaq.Channels.EmailBridge, message_format: :html},
        web: %{bridge: Zaq.Channels.WebBridge, message_format: :plain_text}
      }

  Supported values:

  - `nil` / unset / `:markdown`: source markdown is passed through and stamped
  - `:none`: no transformation and no format stamp
  - `:plain_text`: markdown -> html (`Earmark`) -> plain text
  - `:html`: markdown -> html (`Earmark`)

  Notes:

  - Sanitization is intentionally not applied in this module for now.
  - If channel HTML sanitization is needed, add it in this formatter's markdown
    to HTML step so all channel bridges stay aligned.

  On formatting errors, the original body is kept unchanged.

  `format_outgoing/2` is the canonical public entrypoint.
  """

  alias Zaq.Channels.Bridge
  alias Zaq.Config
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Utils.HtmlUtils

  @doc """
  Formats an outbound message body according to provider `:message_format`
  channel config while preserving all routing and metadata fields.

  Pass `config: ConfigModule` in opts to override runtime configuration.
  With no opts, configuration comes from the application environment.
  """
  @spec format_outgoing(Outgoing.t(), keyword()) :: Outgoing.t()
  def format_outgoing(%Outgoing{} = outgoing, opts \\ []) do
    channels = Config.get(:zaq, :channels, %{}, opts)
    portal_url = Config.get(:zaq, :user_portal_base_url, nil, opts)
    provider_config = provider_channel_config(outgoing.provider, channels)
    format = provider_message_format(provider_config)
    formatter = provider_message_formatter(provider_config)
    metadata = ensure_metadata_map(outgoing.metadata)

    body =
      case outgoing.body do
        text when is_binary(text) -> format_text(text, format, formatter)
        other -> other
      end

    body = maybe_append_budget_exceeded_link(body, outgoing, portal_url)

    %{outgoing | body: body, metadata: put_format_metadata(metadata, format)}
  end

  # Web bridge renders budget exceeded via BO component — no link needed.
  # All other channels get a plain-text URL appended after format conversion
  # so the link survives plain-text and HTML stripping.
  defp maybe_append_budget_exceeded_link(body, %Outgoing{provider: provider}, _portal_url)
       when provider in [:web, "web"],
       do: body

  defp maybe_append_budget_exceeded_link(body, %Outgoing{} = outgoing, portal_url) do
    with :budget_exceeded <- outgoing.metadata[:error_type],
         portal_url when is_binary(portal_url) <- portal_url do
      body <> "\nTop up your wallet: #{portal_url}"
    else
      _ -> body
    end
  end

  # Providers are normalised through `Bridge.provider_to_bridge_key/1` for both
  # atoms and strings. Sub-providers such as `:"email:imap"` are not config keys
  # in their own right — they map back onto `:email`. Using the raw provider as
  # the key made IMAP replies miss `:message_format` and ship as raw markdown.
  defp provider_channel_config(provider, channels) do
    Map.get(channels, Bridge.provider_to_bridge_key(provider), %{})
  end

  # `:markdown` is the default when a channel omits `:message_format` or sets it to
  # nil: source bodies are already markdown and every chat adapter can render it. A
  # channel opts out of formatting explicitly with `message_format: :none`, which
  # normalizes back to `nil` and ships the body without a format stamp.
  defp provider_message_format(provider_config) when is_map(provider_config),
    do: provider_config |> Map.get(:message_format, :markdown) |> normalize_format()

  defp provider_message_format(_provider_config), do: :markdown

  defp provider_message_formatter(provider_config) when is_map(provider_config),
    do: Map.get(provider_config, :message_formatter)

  defp provider_message_formatter(_provider_config), do: nil

  defp normalize_format(nil), do: :markdown
  defp normalize_format(format) when format in ["", :none], do: nil

  defp normalize_format(format) when is_binary(format) do
    String.to_existing_atom(format)
  rescue
    ArgumentError -> nil
  end

  defp normalize_format(format), do: format

  defp format_text(text, _format, {module, function})
       when is_atom(module) and is_atom(function) do
    apply(module, function, [text])
  rescue
    _error -> text
  end

  defp format_text(text, nil, _formatter), do: text

  defp format_text(text, :plain_text, _formatter) do
    case markdown_to_html(text) do
      {:ok, html} -> HtmlUtils.html_to_text(html)
      {:error, _reason} -> text
    end
  end

  defp format_text(text, :html, _formatter) do
    case markdown_to_html(text) do
      {:ok, html} -> html
      {:error, _reason} -> text
    end
  end

  defp format_text(text, _unknown_format, _formatter), do: text

  defp ensure_metadata_map(metadata) when is_map(metadata), do: metadata
  defp ensure_metadata_map(_metadata), do: %{}

  defp put_format_metadata(metadata, format) when format in [:html, :plain_text, :markdown] do
    metadata
    |> Map.delete("format")
    |> Map.put(:format, format)
  end

  defp put_format_metadata(metadata, _format) do
    metadata
    |> Map.delete(:format)
    |> Map.delete("format")
  end

  defp markdown_to_html(text) when is_binary(text) do
    case Earmark.as_html(text, escape: true, breaks: true) do
      {:ok, html, _messages} when is_binary(html) -> {:ok, html}
      {:error, _html, _messages} = error -> error
      other -> {:error, {:invalid_earmark_output, other}}
    end
  rescue
    error -> {:error, error}
  end
end
