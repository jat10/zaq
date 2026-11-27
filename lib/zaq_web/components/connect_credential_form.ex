defmodule ZaqWeb.Components.ConnectCredentialForm do
  @moduledoc """
  Reusable form for creating and editing Connect auth credentials.

  This component is shared by BO pages that manage credentials for
  data sources and system configuration.
  """

  use ZaqWeb, :html

  attr :form, :any, required: true
  attr :changeset, :any, required: true
  attr :errors, :list, default: []
  attr :submit_event, :string, required: true
  attr :change_event, :string, required: true
  attr :cancel_event, :string, required: true
  attr :id_prefix, :string, default: "connect-credential"
  attr :submit_label, :string, default: "Create"
  attr :restore_scopes_event, :string, default: nil
  attr :default_scopes_text, :string, default: ""
  attr :global_settings_path, :string, default: nil
  attr :oauth_behaviours, :list, default: []

  def credential_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="connect-credential-form"
      phx-submit={@submit_event}
      phx-change={@change_event}
      class="space-y-4"
    >
      <div>
        <label class="zaq-field-label-uppercase mb-2 block">
          Name
        </label>
        <input
          type="text"
          name="credential[name]"
          value={@form[:name].value}
          class="zaq-control-text w-full"
          placeholder="e.g. Google Drive OAuth"
        />
      </div>

      <div>
        <label class="zaq-field-label-uppercase mb-2 block">
          Provider
        </label>
        <input
          type="text"
          name="credential[provider]"
          value={@form[:provider].value}
          readonly
          class="zaq-control-text w-full"
          style="background-color: var(--zaq-surface-color-elevated); color: var(--zaq-text-color-body-secondary)"
        />
      </div>

      <div>
        <label class="zaq-field-label-uppercase mb-2 block">
          Request Format
        </label>
        <input
          type="text"
          name="credential[request_format]"
          value={@form[:request_format].value}
          readonly
          class="zaq-control-text w-full"
          style="background-color: var(--zaq-surface-color-elevated); color: var(--zaq-text-color-body-secondary)"
        />
      </div>

      <div>
        <label class="zaq-field-label-uppercase mb-2 block">
          Auth Kind
        </label>
        <select
          name="credential[auth_kind]"
          class="zaq-control-select zaq-control-select--native w-full"
        >
          <option value="oauth2" selected={auth_kind(@changeset) == "oauth2"}>oauth2</option>
          <option value="api_key" selected={auth_kind(@changeset) == "api_key"}>api_key</option>
          <option value="none" selected={auth_kind(@changeset) == "none"}>No authentication</option>
          <option value="jwt_bearer" selected={auth_kind(@changeset) == "jwt_bearer"}>
            jwt_bearer
          </option>
        </select>
        <p
          :if={auth_kind(@changeset) == "none"}
          class="mt-1 zaq-text-body-sm"
          style="color: var(--zaq-text-color-body-tertiary)"
        >
          Requests using this credential will carry no authentication.
        </p>
      </div>

      <div :if={auth_kind(@changeset) == "jwt_bearer"}>
        <label class="zaq-field-label-uppercase mb-2 block">
          Auth Profile
        </label>
        <select
          name="credential[metadata][auth_profile_id]"
          class="zaq-control-select zaq-control-select--native w-full"
        >
          <option
            value="service_account"
            selected={jwt_profile(@changeset) == "service_account"}
          >
            service_account
          </option>
          <option
            value="domain_delegated_service_account"
            selected={jwt_profile(@changeset) == "domain_delegated_service_account"}
          >
            domain_delegated_service_account
          </option>
        </select>
      </div>

      <div :if={auth_kind(@changeset) == "jwt_bearer"}>
        <label class="zaq-field-label-uppercase mb-2 block">
          Issuer
        </label>
        <input
          type="text"
          name="credential[issuer]"
          value={@form[:issuer].value}
          class="zaq-control-text w-full"
        />
      </div>

      <div :if={auth_kind(@changeset) == "jwt_bearer"}>
        <label class="zaq-field-label-uppercase mb-2 block">
          Key ID
        </label>
        <input
          type="text"
          name="credential[key_id]"
          value={@form[:key_id].value}
          class="zaq-control-text w-full"
        />
      </div>

      <div :if={auth_kind(@changeset) == "jwt_bearer"}>
        <label class="zaq-field-label-uppercase mb-2 block">
          Private Key
        </label>
        <ZaqWeb.Components.DesignSystem.SecretInput.secret_input
          id={"#{@id_prefix}-private-key"}
          name="credential[private_key]"
          value={@form[:private_key].value}
          placeholder="••••••••"
          class="w-full"
        />
      </div>

      <div :if={
        auth_kind(@changeset) == "jwt_bearer" &&
          jwt_profile(@changeset) == "domain_delegated_service_account"
      }>
        <label class="zaq-field-label-uppercase mb-2 block">
          Subject
        </label>
        <input
          type="text"
          name="credential[metadata][subject]"
          value={jwt_subject(@form[:metadata].value)}
          class="zaq-control-text w-full"
        />
      </div>

      <div :if={auth_kind(@changeset) == "oauth2" and @oauth_behaviours != []}>
        <label class="zaq-field-label-uppercase mb-2 block">
          OAuth behaviour
        </label>
        <select
          name="credential[metadata][auth_profile]"
          class="zaq-control-select zaq-control-select--native w-full"
        >
          <option
            :for={behaviour <- @oauth_behaviours}
            value={behaviour.id}
            selected={oauth_behaviour(@changeset) == behaviour.id}
          >
            {behaviour.title}
          </option>
        </select>
        <p
          :for={behaviour <- @oauth_behaviours}
          :if={oauth_behaviour(@changeset) == behaviour.id}
          class="mt-1 zaq-text-body-sm"
          style="color: var(--zaq-text-color-body-tertiary)"
        >
          {behaviour.description}
        </p>
      </div>

      <div :if={auth_kind(@changeset) == "oauth2"}>
        <label class="zaq-field-label-uppercase mb-2 block">
          Client ID
        </label>
        <input
          type="text"
          name="credential[client_id]"
          value={@form[:client_id].value}
          class="zaq-control-text w-full"
        />
      </div>

      <div :if={auth_kind(@changeset) == "oauth2"}>
        <label class="zaq-field-label-uppercase mb-2 block">
          Client Secret
        </label>
        <ZaqWeb.Components.DesignSystem.SecretInput.secret_input
          id={"#{@id_prefix}-client-secret"}
          name="credential[client_secret]"
          value={@form[:client_secret].value}
          placeholder="••••••••"
          class="w-full"
        />
      </div>

      <div :if={auth_kind(@changeset) == "oauth2"}>
        <div class="mb-2 flex items-center justify-between gap-2">
          <label class="zaq-field-label-uppercase block">
            Scopes
          </label>
          <button
            :if={@restore_scopes_event && @default_scopes_text != ""}
            type="button"
            phx-click={@restore_scopes_event}
            class="zaq-btn zaq-btn-text_label-default zaq-btn-tertiary"
          >
            Restore defaults
          </button>
        </div>
        <textarea
          name="credential[scopes]"
          rows="3"
          class="zaq-control-text w-full"
          placeholder="drive.readonly, drive.metadata.readonly"
        ><%= scopes_input_value(@form[:scopes].value) %></textarea>
        <p class="mt-1 zaq-text-body-sm" style="color: var(--zaq-text-color-body-tertiary)">
          Comma or newline separated. Defaults are loaded from the provider and can be edited.
        </p>
      </div>

      <div :if={auth_kind(@changeset) == "api_key"}>
        <label class="zaq-field-label-uppercase mb-2 block">
          API Key
        </label>
        <ZaqWeb.Components.DesignSystem.SecretInput.secret_input
          id={"#{@id_prefix}-api-key"}
          name="credential[api_key]"
          value={@form[:api_key].value}
          placeholder="••••••••"
          class="w-full"
        />
      </div>

      <div :if={@errors != []} class="zaq-danger rounded-xl p-3">
        <p
          :for={err <- @errors}
          class="zaq-text-body-sm flex items-center gap-1.5"
        >
          <span>✗</span> {err}
        </p>
        <.link
          :if={
            @global_settings_path &&
              Enum.any?(@errors, &String.contains?(&1, "Global base URL"))
          }
          navigate={@global_settings_path}
          class="mt-2 inline-block zaq-text-body-sm underline zaq-focus-visible"
        >
          Open Global settings
        </.link>
      </div>

      <div class="flex justify-end gap-3 pt-2">
        <button
          type="button"
          phx-click={@cancel_event}
          class="zaq-btn zaq-btn-text_label-default zaq-btn-secondary"
        >
          Cancel
        </button>
        <button
          type="submit"
          class="zaq-btn zaq-btn-text_label-default zaq-btn-primary"
        >
          {@submit_label}
        </button>
      </div>
    </.form>
    """
  end

  defp auth_kind(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.get_field(changeset, :auth_kind, "oauth2")
  end

  defp auth_kind(_), do: "oauth2"

  defp jwt_profile(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.get_field(:metadata, %{})
    |> jwt_profile_from_metadata()
  end

  defp jwt_profile(_), do: "service_account"

  defp jwt_profile_from_metadata(metadata) when is_map(metadata) do
    Map.get(metadata, "auth_profile_id") ||
      Map.get(metadata, :auth_profile_id) ||
      "service_account"
  end

  defp jwt_profile_from_metadata(_), do: "service_account"

  defp jwt_subject(metadata) when is_map(metadata) do
    Map.get(metadata, "subject") || Map.get(metadata, :subject) || ""
  end

  defp jwt_subject(_), do: ""

  defp oauth_behaviour(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.get_field(:metadata, %{})
    |> oauth_behaviour_from_metadata()
  end

  defp oauth_behaviour(_), do: "standard"

  defp oauth_behaviour_from_metadata(metadata) when is_map(metadata) do
    Map.get(metadata, "auth_profile") || Map.get(metadata, :auth_profile) || "standard"
  end

  defp oauth_behaviour_from_metadata(_), do: "standard"

  defp scopes_input_value(scopes) when is_list(scopes) do
    scopes
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
  end

  defp scopes_input_value(scopes) when is_binary(scopes), do: scopes
  defp scopes_input_value(_), do: ""
end
