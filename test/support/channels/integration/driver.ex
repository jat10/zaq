defmodule Zaq.TestSupport.Channels.Integration.Driver do
  @moduledoc """
  Provider-side contract for real communication-channel integration tests.

  `start/1` starts the fake external service before a saved connector exists.
  `connect/2` then starts the real bridge and completes provider authentication
  for that connector. Neither callback may replace ZAQ routing or persistence.
  Native ingress, scripted provider outcomes and captured delivery attempts are
  owned by the driver; agent fixtures and resource cleanup belong to the case.
  """

  alias Zaq.TestSupport.Channels.Integration.Session

  @type handle :: %{
          provider: atom(),
          adapter: module(),
          ingress_mode: atom(),
          connector_attrs: map(),
          sender: map(),
          rooms: %{direct: String.t(), shared: String.t()},
          opaque: term()
        }
  @type capability :: true | {:unsupported, String.t()}
  @type capabilities :: %{
          direct: true,
          shared: true,
          threads: capability(),
          thread_root_lookup: capability(),
          edits: capability()
        }
  @type message_spec :: %{
          required(:content) => String.t(),
          required(:source_id) => String.t(),
          optional(:room) => :direct | :shared,
          optional(:sender) => String.t(),
          optional(:timestamp) => DateTime.t(),
          optional(:mention?) => boolean(),
          optional(:thread_id) => String.t() | nil
        }
  @type emission :: %{source_id: String.t(), channel_id: String.t(), thread_id: String.t() | nil}
  @type script :: %{operation: atom(), match: map(), results: [term()]}
  @type delivery :: %{
          sequence: pos_integer(),
          operation: :send | :edit | :typing,
          provider: atom(),
          channel_config_id: pos_integer(),
          channel_id: String.t(),
          thread_id: String.t() | nil,
          message_id: String.t() | nil,
          text: String.t() | nil,
          outcome: term(),
          native_payload: map()
        }

  @callback start(keyword()) :: {:ok, handle()} | {:error, term()}
  @callback connect(handle(), map()) :: {:ok, handle()} | {:error, term()}
  @callback emit(Session.t(), message_spec()) :: {:ok, emission()} | {:error, term()}
  @callback script(Session.t(), script()) :: :ok | {:error, term()}
  @callback deliveries(Session.t()) :: [delivery()]
  @callback capabilities() :: capabilities()
end
