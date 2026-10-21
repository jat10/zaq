defmodule Zaq.Channels.Integration.FrameworkContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.TestSupport.Channels.Integration.{Contract, Registry, Session}
  alias Zaq.TestSupport.Channels.Integration.ContractFixture

  test "driver implements the contract and reports explicit optional limitations" do
    capabilities = Contract.driver!(:fixture, ContractFixture)
    assert capabilities.direct
    assert capabilities.shared
    assert capabilities.threads == {:unsupported, "Fixture has no native threads"}
  end

  test "missing callbacks and malformed callback results identify the provider and operation" do
    assert_raise ExUnit.AssertionError, ~r/fixture.*start\/1/, fn ->
      Contract.driver!(:fixture, String)
    end

    for {operation, invalid} <- [
          start: {:ok, %{}},
          connect: :ok,
          emit: {:ok, %{}},
          script: {:ok, :ignored},
          deliveries: [%{}]
        ] do
      assert_raise ExUnit.AssertionError, ~r/fixture.*#{operation}/, fn ->
        Contract.result!(:fixture, operation, invalid)
      end
    end

    assert {:error, :offline} = Contract.result!(:fixture, :emit, {:error, :offline})
  end

  test "mandatory capabilities cannot be disabled and unsupported extras need a reason" do
    defaults = ContractFixture.capabilities()

    for capabilities <- [
          Map.delete(defaults, :direct),
          %{defaults | shared: false},
          %{defaults | threads: false},
          %{defaults | edits: {:unsupported, ""}}
        ] do
      assert_raise ExUnit.AssertionError, ~r/fixture.*capabilities/, fn ->
        Contract.capabilities!(:fixture, capabilities)
      end
    end
  end

  test "scripted outcomes and native requests are observable through driver callbacks" do
    {:ok, handle} = ContractFixture.start(owner_pid: self(), scope: "fixture-scope")
    assert {:ok, ^handle} = Contract.result!(:fixture, :start, {:ok, handle})

    session =
      struct!(Session,
        driver: ContractFixture,
        handle: handle,
        scope: "fixture-scope",
        connector: %{id: 1},
        person: %{id: 2},
        agent: %{id: 3},
        observer: self()
      )

    assert :ok =
             ContractFixture.script(session, %{
               operation: :send,
               match: %{content: "Hello"},
               results: [{:error, :offline}]
             })

    assert {:error, :offline} =
             ContractFixture.emit(session, %{content: "Hello", source_id: "one"})

    assert [attempt] = ContractFixture.deliveries(session)
    assert attempt.native_payload == %{content: "Hello", source_id: "one"}
    assert attempt.outcome == {:error, :offline}
    assert [^attempt] = Contract.result!(:fixture, :deliveries, [attempt])

    assert {:error, :unstubbed} =
             ContractFixture.emit(session, %{content: "Hello", source_id: "two"})
  end

  test "native coordinates and delivery ordering are checked, not just key presence" do
    for emission <- [
          %{source_id: "x", channel_id: "room", thread_id: 123},
          %{source_id: "x", channel_id: "", thread_id: nil}
        ] do
      assert_raise ExUnit.AssertionError, ~r/fixture.*emit/, fn ->
        Contract.result!(:fixture, :emit, {:ok, emission})
      end
    end

    {:ok, handle} = ContractFixture.start(owner_pid: self(), scope: "ordering")

    session =
      struct!(Session,
        driver: ContractFixture,
        handle: handle,
        scope: "ordering",
        connector: %{id: 1},
        person: %{id: 2},
        agent: %{id: 3},
        observer: self()
      )

    ContractFixture.emit(session, %{content: "Hello", source_id: "one"})
    [attempt] = ContractFixture.deliveries(session)

    for attempts <- [
          [attempt, attempt],
          [%{attempt | sequence: 2}, attempt],
          [%{attempt | message_id: 42}],
          [%{attempt | operation: :invented}]
        ] do
      assert_raise ExUnit.AssertionError, ~r/fixture.*deliveries/, fn ->
        Contract.result!(:fixture, :deliveries, attempts)
      end
    end
  end

  @tag :tmp_dir
  test "registry rejects duplicate providers/modules and files without an entry", %{tmp_dir: dir} do
    assert_raise ExUnit.AssertionError, ~r/duplicate provider/, fn ->
      Registry.validate!([fixture: ContractFixture, fixture: ContractFixture], files: [])
    end

    assert_raise ExUnit.AssertionError, ~r/duplicate driver/, fn ->
      Registry.validate!([first: ContractFixture, second: ContractFixture], files: [])
    end

    path = Path.join(dir, "forgotten.ex")

    File.write!(
      path,
      "defmodule Zaq.TestSupport.Channels.Integration.Drivers.Forgotten do\nend\n"
    )

    assert_raise ExUnit.AssertionError, ~r/unregistered driver.*forgotten/, fn ->
      Registry.validate!([], files: [path])
    end
  end

  test "coverage reports only Jido communication providers and exposes missing drivers" do
    providers = %{
      fixture: %{bridge: Zaq.Channels.JidoChatBridge, adapter: ContractFixture},
      uncovered: %{bridge: Zaq.Channels.JidoChatBridge, adapter: ContractFixture},
      email: %{bridge: Zaq.Channels.EmailBridge},
      web: %{bridge: Zaq.Channels.WebBridge}
    }

    assert Registry.coverage(providers, fixture: ContractFixture) == %{
             tested: [:fixture],
             missing: [:uncovered]
           }
  end

  property "coverage partitions configured provider identifiers without losing or inventing providers" do
    check all(
            names <- uniq_list_of(string(:alphanumeric, min_length: 1), max_length: 15),
            selected_flags <- list_of(boolean(), length: length(names))
          ) do
      selected = for {name, true} <- Enum.zip(names, selected_flags), do: name
      providers = Map.new(names, &{&1, %{bridge: Zaq.Channels.JidoChatBridge}})
      entries = Enum.map(selected, &{&1, ContractFixture})
      report = Registry.coverage(providers, entries)
      assert report.tested == Enum.sort(selected)
      assert report.missing == Enum.sort(names -- selected)
      assert Enum.sort(report.tested ++ report.missing) == Enum.sort(names)
    end
  end
end
