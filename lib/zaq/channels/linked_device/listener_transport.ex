defmodule Zaq.Channels.LinkedDevice.ListenerTransport do
  @moduledoc "Attaches an adapter decoder to its already-owned linked-device connection."

  alias Zaq.Channels.LinkedDevice.Owner

  @doc false
  def connect(%{profile: profile}, opts), do: Owner.attach(profile, Keyword.fetch!(opts, :parent))
end
