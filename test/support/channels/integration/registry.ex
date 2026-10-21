defmodule Zaq.TestSupport.Channels.Integration.Registry do
  @moduledoc """
  Single deterministic inventory of communication integration-test drivers.

  Entries are added as drivers are implemented. The scaffold task owns the one
  marked literal list; it does not execute test source. Validation also checks
  driver source files, preventing an unregistered integration from disappearing.
  Coverage reports name configured communication providers without a driver.
  """

  import ExUnit.Assertions

  alias Zaq.TestSupport.Channels.Integration.Contract

  # BEGIN CHANNEL INTEGRATION DRIVERS
  @drivers [
    mattermost: Zaq.TestSupport.Channels.Integration.Drivers.Mattermost,
    telegram: Zaq.TestSupport.Channels.Integration.Drivers.Telegram,
    whatsapp: Zaq.TestSupport.Channels.Integration.Drivers.WhatsApp
  ]

  # END CHANNEL INTEGRATION DRIVERS

  @doc "Returns every registered test driver, sorted by provider."
  @spec all() :: [{atom(), module()}]
  def all, do: Enum.sort(@drivers)

  @doc "Validates registrations and scoped source files, returning the sorted inventory."
  @spec validate!([{atom(), module()}], keyword()) :: [{atom(), module()}]
  def validate!(entries \\ all(), opts \\ []) do
    providers = Enum.map(entries, &elem(&1, 0))
    modules = Enum.map(entries, &elem(&1, 1))
    assert length(providers) == length(Enum.uniq(providers)), "duplicate provider registration"
    assert length(modules) == length(Enum.uniq(modules)), "duplicate driver registration"

    for {provider, driver} <- entries do
      assert is_atom(provider) and not is_nil(provider), "provider must be an atom"
      Contract.driver!(provider, driver)
    end

    files =
      Keyword.get_lazy(opts, :files, fn -> Path.wildcard(Path.join(__DIR__, "drivers/*.ex")) end)

    Enum.each(files, &validate_source!(&1, entries))
    Enum.sort(entries)
  end

  @doc "Reports tested/missing configured Jido communication providers without loading drivers."
  @spec coverage(map(), [{atom(), module()}]) :: %{tested: [atom()], missing: [atom()]}
  def coverage(providers, entries \\ all()) do
    registered = MapSet.new(entries, &elem(&1, 0))
    configured = for {provider, %{bridge: Zaq.Channels.JidoChatBridge}} <- providers, do: provider
    {tested, missing} = Enum.split_with(configured, &MapSet.member?(registered, &1))
    %{tested: Enum.sort(tested), missing: Enum.sort(missing)}
  end

  defp validate_source!(file, entries) do
    name = Path.basename(file, ".ex")
    suffix = if name == "whatsapp", do: "WhatsApp", else: Macro.camelize(name)
    expected = "Zaq.TestSupport.Channels.Integration.Drivers." <> suffix
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    assert match?({:defmodule, _, [{:__aliases__, _, _}, _]}, ast),
           "invalid driver module in #{file}"

    {:defmodule, _, [{:__aliases__, _, parts}, _]} = ast
    declared = Enum.map_join(parts, ".", &Atom.to_string/1)
    assert declared == expected, "invalid driver namespace in #{file}: expected #{expected}"

    assert Enum.any?(entries, fn {provider, driver} ->
             Atom.to_string(provider) == name and inspect(driver) == expected
           end),
           "unregistered driver #{name} in #{file}"
  end
end
