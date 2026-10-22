defmodule Zaq.CredentialDocumentFixtures do
  @moduledoc false

  alias Zaq.Engine.Connect
  alias Zaq.Repo

  def document(binding, op, fields \\ %{}),
    do: Connect.credential_document(Map.merge(fields, %{binding: binding, op: op}))

  def credential_document_fixture do
    config = Zaq.WhatsAppFixtures.connector(%{name: "Document #{Ecto.UUID.generate()}"})

    {:ok, saved} =
      Connect.save_credential_configuration(
        nil,
        %{
          name: "document-#{Ecto.UUID.generate()}",
          provider: config.provider,
          auth_kind: "api_key",
          secret_binding: :grant,
          personal_credential_policy: :disabled,
          metadata: %{
            "auth_profile_id" => "credential_document_v1",
            "subject" => "channel_config:#{config.id}"
          }
        },
        {:replace, %{api_key: ~s({"version":1,"records":{}})}}
      )

    config
    |> Ecto.Changeset.change(settings: %{"credential_document_id" => saved.credential_id})
    |> Repo.update!()

    %{channel_config_id: config.id, credential_id: saved.credential_id}
  end
end
