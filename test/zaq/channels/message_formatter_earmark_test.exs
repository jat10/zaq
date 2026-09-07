defmodule Zaq.Channels.MessageFormatterEarmarkTest do
  # Replacing Earmark changes VM-wide code and must remain synchronous.
  use ExUnit.Case, async: false

  alias Zaq.Channels.MessageFormatter
  alias Zaq.Engine.Messages.Outgoing

  defmodule TestConfig do
    def get(:zaq, key, default, opts), do: Keyword.get(opts, key, default)
  end

  test "I: invalid Earmark output falls back to the original body" do
    with_mocked_earmark_as_html(fn ->
      channels = %{web: %{bridge: Zaq.Channels.WebBridge, message_format: :html}}

      outgoing = %Outgoing{
        provider: :web,
        channel_id: "c1",
        body: "# Title",
        metadata: %{request_id: "r1"}
      }

      formatted =
        MessageFormatter.format_outgoing(outgoing, config: TestConfig, channels: channels)

      assert formatted.body == "# Title"
      assert formatted.metadata[:format] == :html
      assert formatted.metadata[:request_id] == "r1"

      channels = %{web: %{bridge: Zaq.Channels.WebBridge, message_format: :plain_text}}

      formatted =
        MessageFormatter.format_outgoing(outgoing, config: TestConfig, channels: channels)

      assert formatted.body == "# Title"
      assert formatted.metadata[:format] == :plain_text
      assert formatted.metadata[:request_id] == "r1"
    end)
  end

  defp with_mocked_earmark_as_html(fun) when is_function(fun, 0) do
    :code.purge(Earmark)
    :code.delete(Earmark)

    Code.compiler_options(ignore_module_conflict: true)

    Code.compile_string("""
    defmodule Earmark do
      def as_html(_text, _opts), do: :weird
    end
    """)

    Code.compiler_options(ignore_module_conflict: false)

    try do
      fun.()
    after
      :code.purge(Earmark)
      :code.delete(Earmark)
      :code.load_file(Earmark)
      Code.compiler_options(ignore_module_conflict: false)
    end
  end
end
