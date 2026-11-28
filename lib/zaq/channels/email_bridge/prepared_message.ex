defmodule Zaq.Channels.EmailBridge.PreparedMessage do
  @moduledoc "Transient encoded MIME and frozen SMTP envelope; never persistence or telemetry data."

  @enforce_keys [:body, :size_bytes, :config, :sender, :recipients]
  @derive {Inspect, only: []}
  defstruct [:body, :size_bytes, :config, :sender, :recipients]
end
