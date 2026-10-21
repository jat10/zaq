defmodule Mix.Tasks.Zaq.Test.Gen.ChannelTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Mix.Tasks.Zaq.Test.Gen.Channel
  alias Zaq.TestSupport.Channels.Integration.Contract

  @support Path.expand("../../support/channels/integration", __DIR__)
  @moduletag :tmp_dir

  defmodule Adapter do
    @moduledoc false
    def channel_type, do: :generator_fixture
    def transform_incoming(_), do: {:error, :fixture_only}
    def send_message(_, _, _), do: {:error, :fixture_only}
  end

  setup %{tmp_dir: root} do
    support = Path.join(root, "test/support/channels/integration")
    File.mkdir_p!(support)
    File.cp!(Path.join(@support, "registry.ex"), Path.join(support, "registry.ex"))
    File.cp_r!(Path.join(@support, "templates"), Path.join(support, "templates"))
    %{root: root, registry: Path.join(support, "registry.ex")}
  end

  test "creates two executable skeletons and exactly one sorted literal registration", context do
    before = File.read!(context.registry)
    plan = Channel.plan!(args("teams"), context.root)
    assert length(plan.files) == 2
    assert File.read!(context.registry) == before
    assert :ok = Channel.apply_plan!(plan)
    assert Enum.all?(plan.files, fn {path, source} -> File.read!(path) == source end)
    assert length(:binary.matches(File.read!(context.registry), "teams:")) == 1
    assert File.read!(context.registry) == plan.updated

    assert plan.updated =~
             "teams: Zaq.TestSupport.Channels.Integration.Drivers.Teams,\n    telegram:"

    assert {:ok, _} = Code.string_to_quoted(plan.updated)

    [{_path, source}, {_test_path, test_source}] = plan.files
    assert {:ok, _} = Code.string_to_quoted(test_source)
    refute test_source =~ "@tag :skip"
    refute source =~ "app.start"
    [{driver, _}] = Code.compile_string(source)

    on_exit(fn ->
      :code.purge(driver)
      :code.delete(driver)
    end)

    assert_raise RuntimeError, ~r/teams: implement capabilities/, fn ->
      Contract.driver!(:teams, driver)
    end

    assert_raise RuntimeError, ~r/teams: implement start/, fn -> driver.start([]) end

    assert_raise Mix.Error, ~r/already registered/, fn ->
      Channel.plan!(args("teams"), context.root)
    end
  end

  test "dry run is deterministic and byte-for-byte write free", context do
    before = snapshot(context.root)
    first = Channel.plan!(args("teams") ++ ["--dry-run"], context.root)
    second = Channel.plan!(args("teams") ++ ["--dry-run"], context.root)
    assert first == second
    assert :ok = Channel.apply_plan!(first)
    assert snapshot(context.root) == before
    assert first.diff =~ "+    teams:"
  end

  test "the dev task runs without test support or starting application services" do
    script = """
    before_apps = Application.started_applications() |> Enum.map(&elem(&1, 0))
    false = :zaq in before_apps
    false = Code.ensure_loaded?(Zaq.TestSupport.Channels.Integration.Driver)
    Mix.Task.run("zaq.test.gen.channel", ["fixture_new", "--adapter", "Jido.Chat.Mattermost.Adapter", "--dry-run"])
    false = Application.started_applications() |> Enum.any?(&(elem(&1, 0) == :zaq))
    nil = Process.whereis(Zaq.Repo)
    false = Code.ensure_loaded?(Zaq.TestSupport.Channels.Integration.Driver)
    IO.puts("NO_APPLICATION_OR_TEST_SUPPORT_STARTED")
    """

    {output, status} =
      System.cmd("mix", ["run", "--no-start", "-e", script],
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    assert status == 0, String.slice(output, -1500, 1500)
    assert output =~ "NO_APPLICATION_OR_TEST_SUPPORT_STARTED"
    assert output =~ "create test/support/channels/integration/drivers/fixture_new.ex"
    refute File.exists?("test/support/channels/integration/drivers/fixture_new.ex")
  end

  test "rejects malformed identifiers and unknown, duplicate or missing arguments without writes",
       context do
    before = snapshot(context.root)

    for input <- [
          [],
          ["../teams"],
          args("Teams"),
          args("a/b"),
          args("teams") ++ ["extra"],
          args("teams") ++ ["--force"],
          args("teams") ++ ["--adapter", inspect(Adapter)],
          args("teams") ++ ["--dry-run", "--dry-run"],
          ["teams", "--adapter", "bad.module"],
          ["teams", "--adapter", "Missing.Channel.Adapter"],
          ["teams", "--adapter", "Enum.Map"],
          ["teams", "--adapter", "String.Chars"]
        ] do
      assert_raise Mix.Error, fn -> Channel.plan!(input, context.root) end
      assert snapshot(context.root) == before
    end
  end

  test "existing targets are preserved and cause zero writes", context do
    plan = Channel.plan!(args("teams"), context.root)
    {path, _} = hd(plan.files)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "existing implementation")
    before = snapshot(context.root)

    assert_raise Mix.Error, ~r/Already exists/, fn ->
      Channel.plan!(args("teams"), context.root)
    end

    assert snapshot(context.root) == before
  end

  test "missing, duplicated, reversed or executable registry markers fail before writing",
       context do
    original = File.read!(context.registry)

    for source <- [
          String.replace(original, "# BEGIN CHANNEL INTEGRATION DRIVERS", "missing"),
          original <> "\n  # END CHANNEL INTEGRATION DRIVERS\n",
          "  # END CHANNEL INTEGRATION DRIVERS\n  # BEGIN CHANNEL INTEGRATION DRIVERS\n",
          "  # BEGIN CHANNEL INTEGRATION DRIVERS\n  @drivers System.cmd(\"false\", [])\n  # END CHANNEL INTEGRATION DRIVERS\n"
        ] do
      File.write!(context.registry, source)
      before = snapshot(context.root)
      assert_raise Mix.Error, fn -> Channel.plan!(args("teams"), context.root) end
      assert snapshot(context.root) == before
    end
  end

  test "symlink output and template paths cannot escape test/", context do
    outside = Path.join(context.root, "outside")
    File.mkdir!(outside)
    drivers = Path.join(context.root, "test/support/channels/integration/drivers")
    File.ln_s!(outside, drivers)
    before = snapshot(context.root)
    assert_raise Mix.Error, ~r/symlink/, fn -> Channel.plan!(args("teams"), context.root) end
    assert snapshot(context.root) == before
    assert File.ls!(outside) == []
  end

  test "concurrent registry edits are preserved and stale plans create no outputs", context do
    plan = Channel.plan!(args("teams"), context.root)
    concurrent = plan.original <> "\n# another writer\n"
    File.write!(context.registry, concurrent)
    assert_raise Mix.Error, ~r/Registry changed/, fn -> Channel.apply_plan!(plan) end
    assert File.read!(context.registry) == concurrent
    refute Enum.any?(plan.files, fn {path, _} -> File.exists?(path) end)
  end

  test "another generator's lock is preserved and prevents competing writes", context do
    plan = Channel.plan!(args("teams"), context.root)
    lock = context.registry <> ".channel.lock"
    File.write!(lock, "other invocation")
    before = snapshot(context.root)
    assert_raise Mix.Error, ~r/already in progress/, fn -> Channel.apply_plan!(plan) end
    assert snapshot(context.root) == before
  end

  test "a later write failure rolls back owned files and preserves the registry", context do
    plan = Channel.plan!(args("teams"), context.root)
    {_first_path, _} = hd(plan.files)
    {second, _} = Enum.at(plan.files, 1)
    directory = Path.dirname(second)
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o555)

    try do
      assert_raise File.Error, fn -> Channel.apply_plan!(plan) end
      assert File.read!(context.registry) == plan.original
      refute Enum.any?(plan.files, fn {path, _} -> File.exists?(path) end)
    after
      File.chmod!(directory, 0o755)
    end
  end

  property "bounded lowercase identifiers generate only contained deterministic test paths",
           context do
    check all(suffix <- string(?a..?z, min_length: 1, max_length: 15), max_runs: 25) do
      provider = "fixture_" <> suffix
      plan = Channel.plan!(args(provider) ++ ["--dry-run"], context.root)

      assert Enum.all?(plan.files, fn {path, _} ->
               String.starts_with?(path, context.root <> "/test/")
             end)

      assert Enum.map(plan.files, &elem(&1, 0)) |> Enum.uniq() |> length() == 2
      assert :ok = Channel.apply_plan!(plan)
      refute Enum.any?(plan.files, fn {path, _} -> File.exists?(path) end)
    end
  end

  defp args(provider), do: [provider, "--adapter", inspect(Adapter)]

  defp snapshot(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.map(fn path ->
      {Path.relative_to(path, root), File.lstat!(path).type, File.read(path)}
    end)
  end
end
