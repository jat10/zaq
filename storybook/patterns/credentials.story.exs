defmodule Storybook.Patterns.Credentials do
  use PhoenixStorybook.Story, :page

  alias Zaq.Engine.Connect.Credential

  def description,
    do: "Credential controls, readonly values and validation feedback. Use the theme switch to inspect both palettes."

  def render(assigns) do
    changeset =
      Ecto.Changeset.change(%Credential{}, %{
        name: "Company Drive",
        provider: "google_drive",
        auth_kind: "oauth2",
        request_format: "bearer",
        client_id: "example-client",
        scopes: ["drive.readonly"],
        metadata: %{}
      })

    assigns =
      assigns
      |> assign(:changeset, changeset)
      |> assign(:form, Phoenix.Component.to_form(changeset, as: :credential))

    ~H"""
    <div class="zaq-card-default zaq-card-hover max-w-2xl">
      <ZaqWeb.Components.ConnectCredentialForm.credential_form
        form={@form}
        changeset={@changeset}
        submit_event="save_credential"
        change_event="validate_credential"
        cancel_event="close_credential_form"
        restore_scopes_event="restore_scopes"
        default_scopes_text="drive.readonly"
        errors={["Global base URL must be configured before authorization."]}
        global_settings_path="/bo/system-config"
      />
    </div>
    """
  end
end
