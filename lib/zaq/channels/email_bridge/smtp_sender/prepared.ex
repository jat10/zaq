defmodule Zaq.Channels.EmailBridge.SmtpSender.Prepared do
  @moduledoc "Private MIME representation measured and submitted by SmtpSender in one attempt."

  @enforce_keys [:email, :body, :encoded_bytes]
  @derive {Inspect, only: [:encoded_bytes]}
  defstruct [:email, :body, :encoded_bytes]

  @type t :: %__MODULE__{
          email: Swoosh.Email.t(),
          body: binary(),
          encoded_bytes: non_neg_integer()
        }
end
