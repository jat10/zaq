defmodule Zaq.Channels.DataSourceBridgeFacade do
  @moduledoc """
  Provider-neutral DataSource facade contract used by Channels role events.

  Implementations of this behaviour receive provider names, canonical records,
  caller params, and trusted context from `Zaq.Channels.Api`. The default
  implementation is `Zaq.Channels.DataSourceBridge`, which resolves the concrete
  provider bridge and channel config before invoking provider callbacks.
  """

  alias Zaq.Contracts.Record
  alias Zaq.Contracts.RecordPage
  alias Zaq.Events.TrustedContext

  @callback auth_handshake(atom() | String.t(), map()) :: {:ok, term()} | {:error, term()}
  @callback list_resources(atom() | String.t(), map()) :: {:ok, RecordPage.t()} | {:error, term()}
  @callback download_resource(atom() | String.t(), map(), map()) ::
              {:ok, term()} | {:error, term()}
  @callback setup_listener(atom() | String.t(), map()) :: {:ok, term()} | {:error, term()}
  @callback watch_item(atom() | String.t(), map()) :: {:ok, term()} | {:error, term()}
  @callback unwatch_item(atom() | String.t(), map()) :: :ok | {:ok, term()} | {:error, term()}
  @callback list_source_scopes(atom() | String.t(), map()) :: {:ok, [map()]} | {:error, term()}

  @callback list_files(atom() | String.t(), map(), map() | TrustedContext.t()) ::
              {:ok, RecordPage.t()} | {:error, term()}

  @callback create_file(atom() | String.t(), map(), map() | TrustedContext.t()) ::
              {:ok, map()} | {:error, term()}

  @callback get_file(atom() | String.t(), map(), map() | TrustedContext.t()) ::
              {:ok, map()} | {:error, term()}

  @callback update_file(Record.t(), map(), map() | TrustedContext.t()) ::
              {:ok, map()} | {:error, term()}

  @callback delete_file(Record.t(), map() | TrustedContext.t()) :: {:ok, map()} | {:error, term()}

  @callback search_files(atom() | String.t(), map(), map() | TrustedContext.t()) ::
              {:ok, RecordPage.t()} | {:error, term()}

  @callback download_document(atom() | String.t(), map(), map() | TrustedContext.t()) ::
              {:ok, map()} | {:error, term()}

  @callback list_permissions(atom() | String.t(), map(), map() | TrustedContext.t()) ::
              {:ok, RecordPage.t()} | {:error, term()}

  @callback replace_permissions(atom() | String.t(), map(), map() | TrustedContext.t()) ::
              {:ok, map()} | {:error, term()}

  @callback teardown_listener(atom() | String.t(), map()) :: :ok | {:error, term()}
  @callback channel_stats(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback export_options(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback sheet_inspect(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback sheet_get(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback sheet_create(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback sheet_add_tab(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback sheet_update_values(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback sheet_append_values(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback sheet_clear_values(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback sheet_delete_tab(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback oauth_authorize_url(atom() | String.t(), map()) ::
              {:ok, String.t()} | {:error, term()}
  @callback oauth_exchange_code(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback oauth_refresh_token(atom() | String.t(), map(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback oauth_default_scopes(atom() | String.t()) :: {:ok, [String.t()]} | {:error, term()}
  @callback handle_webhook(atom() | String.t(), map()) :: {:ok, term()} | {:error, term()}
  @callback capability_snapshot(atom() | String.t()) :: {:ok, map()} | {:error, term()}
  @callback capability_snapshot(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
end
