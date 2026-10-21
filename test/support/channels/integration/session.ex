defmodule Zaq.TestSupport.Channels.Integration.Session do
  @moduledoc """
  Test-owned provider handle, saved identities and resource ownership.

  Provider details stay opaque in `handle`; tests retain the connector, Person
  and configured agent so observations can be correlated to persisted outcomes.
  Resources identify only processes started for this session.
  """

  @enforce_keys [:driver, :handle, :scope, :connector, :person, :agent, :observer]
  defstruct @enforce_keys ++ [resources: []]

  @type t :: %__MODULE__{
          driver: module(),
          handle: map(),
          scope: String.t(),
          connector: map(),
          person: map(),
          agent: map(),
          observer: pid(),
          resources: [term()]
        }
end
