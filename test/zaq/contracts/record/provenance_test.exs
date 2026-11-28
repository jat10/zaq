defmodule Zaq.Contracts.Record.ProvenanceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Accounts.Person
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.{Authorization, Provenance}

  property "changing the authorized nested identity invalidates provenance" do
    check all(
            suffix <- string(:alphanumeric, min_length: 1, max_length: 24),
            representation <- member_of([:channel, :type, :atoms])
          ) do
      owner = "owner-#{suffix}@example.test"
      attacker = "attacker-#{suffix}@example.test"
      record = seal(%{"principal" => principal(representation, owner)})
      person = %Person{id: 1, email: attacker, channels: []}

      refute Authorization.can?(person, record, :read)

      forged =
        update_attrs(record, &Map.put(&1, "principal", principal(representation, attacker)))

      assert Authorization.can?(person, forged, :read)
      assert {:error, :record_provenance_mismatch} = Provenance.verify(forged)
      assert {:ok, _claims} = Provenance.verify(record)
    end
  end

  test "shared principal projection preserves authorization precedence" do
    attrs = %{
      "principal" => %{channel: " EMAIL ", identifier: " Owner@example.test "},
      "principal_type" => "mattermost",
      "principal_key" => "different-user"
    }

    assert Authorization.principal(attrs) == {"email", "Owner@example.test"}
    assert Authorization.principal(Map.put(attrs, "principal", %{})) == nil
  end

  test "changing nested principal type, identifier or rights rejects every Record boundary" do
    record = seal(%{"principal" => principal(:channel, "owner@example.test")})

    for changed <- [
          %{"principal" => %{"channel" => "mattermost", "identifier" => "owner@example.test"}},
          %{"principal" => principal(:channel, "attacker@example.test")},
          %{"access_rights" => ["edit"]}
        ] do
      forged = update_attrs(record, &Map.merge(&1, changed))
      assert {:error, :record_provenance_mismatch} = Provenance.verify(forged)
      assert {:error, _reason} = forged |> Map.from_struct() |> Record.from_map()
      assert {:error, _errors} = Zoi.parse(Record.zoi_type(), forged)

      assert {:error, :record_provenance_mismatch} =
               Provenance.verify(forged, skip_permissions: true)
    end
  end

  test "an invalid nested principal cannot alias a valid flat grant" do
    person = %Person{id: 1, email: "owner@example.test", channels: []}

    for nested <- [%{}, %{"channel" => "email"}, %{"channel" => "email", "identifier" => 12}] do
      record = seal(%{"principal" => nested})
      refute Authorization.can?(person, record, :read)

      forged = update_attrs(record, &Map.delete(&1, "principal"))
      assert Authorization.can?(person, forged, :read)
      assert {:error, :record_provenance_mismatch} = Provenance.verify(forged)
    end
  end

  test "flat channel overrides and provider fields are independently bound" do
    record = seal(%{"principal_channel" => "mattermost"})

    for changed <- [
          %{"principal_channel" => "email"},
          %{"principal_type" => "slack"},
          %{"principal_key" => "other-user"}
        ] do
      assert {:error, :record_provenance_mismatch} =
               record |> update_attrs(&Map.merge(&1, changed)) |> Provenance.verify()
    end
  end

  test "an unmatched flat principal cannot alias a nested authorized grant" do
    record = seal(%{"principal_type" => "provider-user"})

    forged =
      update_attrs(record, &Map.put(&1, "principal", principal(:channel, "owner@example.test")))

    person = %Person{id: 1, email: "owner@example.test", channels: []}

    refute Authorization.can?(person, record, :read)
    assert Authorization.can?(person, forged, :read)
    assert {:error, :record_provenance_mismatch} = Provenance.verify(forged)
  end

  test "flat provider principal signatures retain their existing projection" do
    record = seal(%{})
    assert {:ok, claims} = Provenance.verify(record)
    assert [entry] = claims["permissions"]["entries"]
    assert entry["principal"] == %{"type" => "email", "key" => "owner@example.test"}
  end

  test "earlier signatures without nested identity binding require trusted reissue" do
    flat = seal(%{})

    legacy_nested =
      update_attrs(flat, &Map.put(&1, "principal", principal(:channel, "owner@example.test")))

    assert {:error, :record_provenance_mismatch} = Provenance.verify(legacy_nested)
    assert {:error, _errors} = Zoi.parse(Record.zoi_type(), legacy_nested)

    assert {:ok, reissued} = Provenance.seal(legacy_nested)
    assert {:ok, _claims} = Provenance.verify(reissued)
    refute Authorization.can?(nil, reissued, :read)

    assert Authorization.can?(
             %Person{id: 1, email: "owner@example.test", channels: []},
             reissued,
             :read
           )
  end

  property "valid nested permission Records survive JSON and schema round trips" do
    check all(
            suffix <- string(:alphanumeric, min_length: 1, max_length: 24),
            representation <- member_of([:channel, :type, :atoms])
          ) do
      email = "owner-#{suffix}@example.test"
      record = seal(%{"principal" => principal(representation, email)})
      assert {:ok, restored} = record |> Jason.encode!() |> Jason.decode!() |> Record.from_map()
      assert {:ok, _claims} = Provenance.verify(restored)
      assert {:ok, %Record{}} = Zoi.parse(Record.zoi_type(), restored)
      assert Authorization.can?(%Person{id: 1, email: email, channels: []}, restored, :read)
    end
  end

  test "equivalent nested key representations and whitespace preserve signatures" do
    record = seal(%{"principal" => principal(:channel, "owner@example.test")})

    equivalent =
      update_attrs(
        record,
        &Map.put(&1, "principal", %{type: " EMAIL ", key: " OWNER@example.test "})
      )

    assert {:ok, _claims} = Provenance.verify(equivalent)

    assert Authorization.can?(
             %Person{id: 1, email: "owner@example.test", channels: []},
             equivalent,
             :read
           )
  end

  test "removing or weakening loaded permission evidence fails closed" do
    record = seal(%{"principal" => principal(:channel, "owner@example.test")})

    for permissions <- [nil, []] do
      assert {:error, :record_provenance_mismatch} =
               Provenance.verify(%{record | permissions: permissions})
    end
  end

  defp seal(attrs) do
    permission = %Record{
      id: "acl",
      kind: :permission,
      attributes:
        Map.merge(
          %{
            "principal_type" => "email",
            "principal_key" => "owner@example.test",
            "access_rights" => ["read"]
          },
          attrs
        )
    }

    {:ok, record} =
      Provenance.seal(%Record{id: "document", kind: :file, permissions: [permission]})

    record
  end

  defp update_attrs(%Record{permissions: [permission]} = record, update) do
    %{record | permissions: [%{permission | attributes: update.(permission.attributes)}]}
  end

  defp principal(:channel, email), do: %{"channel" => "email", "identifier" => email}
  defp principal(:type, email), do: %{"type" => "email", "key" => email}
  defp principal(:atoms, email), do: %{channel: "email", identifier: email}
end
