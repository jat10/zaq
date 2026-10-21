defmodule Mix.Tasks.Zaq.Test.Gen.Channel do
  @moduledoc """
  Scaffolds a communication integration-test driver for an installed adapter.

      mix zaq.test.gen.channel teams --adapter Jido.Chat.Teams.Adapter --dry-run
      mix zaq.test.gen.channel teams --adapter Jido.Chat.Teams.Adapter

  The adapter must already compile and implement channel_type/0,
  transform_incoming/1 and send_message/3. This task compiles without starting
  ZAQ, Repo or provider runtimes. It never creates a production adapter.

  Creates a driver and provider test under test/, and registers the driver in
  the common matrix. Stubs fail explicitly until implemented. Existing files,
  duplicate registrations, malformed markers and symlink paths are rejected.
  There is no force or output-directory option. Dry runs make no file changes.
  """
  use Mix.Task

  @shortdoc "Scaffolds a registered communication integration-test driver"
  @registry "test/support/channels/integration/registry.ex"
  @templates "test/support/channels/integration/templates"
  @begin_marker "  # BEGIN CHANNEL INTEGRATION DRIVERS"
  @end_marker "  # END CHANNEL INTEGRATION DRIVERS"
  @namespace "Zaq.TestSupport.Channels.Integration.Drivers."

  @impl true
  def run(args) do
    # Match the repository's compile-only developer tasks; never app.start.
    Mix.Task.run("compile", [])
    plan = plan!(args, File.cwd!())

    Enum.each(plan.files, fn {path, _} ->
      Mix.shell().info("create #{Path.relative_to(path, plan.root)}")
    end)

    Mix.shell().info("update #{@registry}\n#{plan.diff}")
    unless plan.dry_run, do: apply_plan!(plan)
  end

  @doc "Builds a validated, write-free scaffold plan relative to a project root."
  def plan!(args, root) do
    {provider, adapter, dry_run} = arguments!(args)
    validate_adapter!(adapter)
    root = Path.expand(root)
    registry = safe_path!(root, @registry)
    original = File.read!(registry)
    {updated, diff} = registration!(original, provider)

    assigns = [
      provider: provider,
      driver: @namespace <> Macro.camelize(provider),
      adapter: adapter
    ]

    files =
      for {template, target} <- [
            {"driver.ex.eex", "test/support/channels/integration/drivers/#{provider}.ex"},
            {"provider_test.exs.eex",
             "test/zaq/channels/integration/providers/#{provider}_test.exs"}
          ] do
        path = safe_path!(root, target)
        absent!(path)
        source = safe_path!(root, Path.join(@templates, template))
        body = EEx.eval_file(source, assigns: assigns) |> format_source!()
        {path, body}
      end

    %{
      root: root,
      registry: registry,
      original: original,
      updated: updated,
      files: files,
      dry_run: dry_run,
      diff: diff
    }
  end

  @doc "Applies a scaffold plan, refusing stale registry data and existing destinations."
  def apply_plan!(%{dry_run: true}), do: :ok

  def apply_plan!(plan) do
    lock = plan.registry <> ".channel.lock"
    safe_path!(plan.root, Path.relative_to(lock, plan.root))

    case File.open(lock, [:write, :exclusive]) do
      {:ok, io} ->
        try do
          apply_outputs!(plan)
        after
          File.close(io)
          File.rm(lock)
        end

      {:error, :eexist} ->
        Mix.raise("Channel scaffold generation is already in progress; inspect #{lock}")

      {:error, reason} ->
        raise File.Error, reason: reason, action: "lock generator", path: lock
    end
  end

  defp apply_outputs!(plan) do
    for path <- [plan.registry | Enum.map(plan.files, &elem(&1, 0))],
        do: safe_path!(plan.root, Path.relative_to(path, plan.root))

    Enum.each(plan.files, fn {path, _} -> absent!(path) end)
    unchanged!(plan)
    directories = missing_directories(plan.files, plan.root)

    try do
      Enum.each(directories, &File.mkdir!/1)
      write_outputs!(plan.files, fn -> replace_registry!(plan) end)
    rescue
      error ->
        directories |> Enum.reverse() |> Enum.each(&File.rmdir/1)
        reraise error, __STACKTRACE__
    end
  end

  defp arguments!(args) do
    raw_options =
      args
      |> Enum.filter(&String.starts_with?(&1, "--"))
      |> Enum.map(&(&1 |> String.split("=", parts: 2) |> hd()))

    unless length(raw_options) == length(Enum.uniq(raw_options)) and
             Enum.all?(raw_options, &(&1 in ["--adapter", "--dry-run"])),
           do: usage!()

    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [adapter: :string, dry_run: :boolean])

    keys = Keyword.keys(opts)

    unless invalid == [] and length(positional) == 1 and length(keys) == length(Enum.uniq(keys)),
      do: usage!()

    [provider] = positional
    adapter = Keyword.get(opts, :adapter, "")
    unless Regex.match?(~r/^[a-z][a-z0-9_]*$/, provider), do: usage!()
    unless Regex.match?(~r/^[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)+$/, adapter), do: usage!()
    {provider, adapter, Keyword.get(opts, :dry_run, false)}
  end

  defp usage! do
    Mix.raise(
      "Usage: mix zaq.test.gen.channel <lowercase_provider> --adapter Elixir.Module [--dry-run]; unknown or duplicate options are not allowed"
    )
  end

  defp validate_adapter!(name) do
    module = Module.concat(String.split(name, "."))
    required = [channel_type: 0, transform_incoming: 1, send_message: 3]

    unless Code.ensure_loaded?(module) and
             Enum.all?(required, fn {fun, arity} -> function_exported?(module, fun, arity) end),
           do:
             Mix.raise(
               "Adapter #{name} is unavailable or incompatible. Install and compile its production integration separately; no files were generated."
             )
  end

  defp registration!(source, provider) do
    unless length(:binary.matches(source, @begin_marker)) == 1 and
             length(:binary.matches(source, @end_marker)) == 1,
           do: Mix.raise("Registry must contain exactly one pair of channel integration markers")

    {begin_at, _} = :binary.match(source, @begin_marker)
    {end_at, _} = :binary.match(source, @end_marker)
    if begin_at >= end_at, do: Mix.raise("Registry markers must appear in begin/end order")

    [before, owned] = String.split(source, @begin_marker)
    [block, rest] = String.split(owned, @end_marker)
    entries = registry_entries!(block)

    if Enum.any?(entries, fn {key, _} -> key == provider end),
      do:
        Mix.raise(
          "Driver #{provider} is already registered; finish its existing integration instead"
        )

    entries = Enum.sort([{provider, @namespace <> Macro.camelize(provider)} | entries])

    rendered =
      "\n  @drivers [\n" <>
        Enum.map_join(entries, ",\n", fn {key, module} -> "    #{key}: #{module}" end) <>
        "\n  ]\n"

    updated = before <> @begin_marker <> rendered <> @end_marker <> rest
    syntax!(updated)

    {updated,
     "-" <> String.replace(block, "\n", "\n-") <> "\n+" <> String.replace(rendered, "\n", "\n+")}
  end

  defp registry_entries!(block) do
    case Code.string_to_quoted(block) do
      {:ok, {:@, _, [{:drivers, _, [entries]}]}} when is_list(entries) ->
        entries = Enum.map(entries, &literal_entry!/1)

        unless length(entries) == length(Enum.uniq_by(entries, &elem(&1, 0))),
          do: Mix.raise("Registry contains duplicate provider entries")

        entries

      _ ->
        Mix.raise("Registry marker block must contain only a literal @drivers list")
    end
  end

  defp literal_entry!({provider, {:__aliases__, _, parts}}) when is_atom(provider) do
    module = Enum.map_join(parts, ".", &Atom.to_string/1)

    unless String.starts_with?(module, @namespace),
      do: Mix.raise("Invalid driver namespace in registry")

    {Atom.to_string(provider), module}
  end

  defp literal_entry!(_),
    do: Mix.raise("Registry entries must be literal provider: Driver.Module pairs")

  defp safe_path!(root, relative) do
    path = Path.expand(relative, root)
    test_root = Path.join(root, "test")

    unless String.starts_with?(path, test_root <> "/"),
      do: Mix.raise("Generator output must stay under test/")

    parts = Path.relative_to(path, root) |> Path.split()

    Enum.reduce(parts, root, fn part, parent ->
      current = Path.join(parent, part)

      case File.lstat(current) do
        {:ok, %{type: :symlink}} -> Mix.raise("Refusing symlink path #{current}")
        _ -> :ok
      end

      current
    end)
  end

  defp absent!(path) do
    unless match?({:error, :enoent}, File.lstat(path)),
      do:
        Mix.raise("Already exists: #{path}; finish or remove the existing integration explicitly")
  end

  defp syntax!(source) do
    case Code.string_to_quoted(source) do
      {:ok, _} -> :ok
      {:error, reason} -> Mix.raise("Generated Elixir is invalid: #{inspect(reason)}")
    end
  end

  defp format_source!(source) do
    syntax!(source)
    (source |> Code.format_string!() |> IO.iodata_to_binary()) <> "\n"
  end

  defp unchanged!(plan) do
    unless File.read!(plan.registry) == plan.original,
      do:
        Mix.raise("Registry changed during generation; retry after reviewing the concurrent edit")
  end

  defp missing_directories(files, root) do
    files
    |> Enum.flat_map(fn {path, _} -> ancestor_directories(Path.dirname(path), root) end)
    |> Enum.uniq()
    |> Enum.sort_by(&length(Path.split(&1)))
    |> Enum.reject(&File.dir?/1)
  end

  defp ancestor_directories(path, root) when path == root, do: []

  defp ancestor_directories(path, root),
    do: ancestor_directories(Path.dirname(path), root) ++ [path]

  defp write_outputs!([], commit), do: commit.()

  defp write_outputs!([{path, body} | rest], commit) do
    io = File.open!(path, [:write, :exclusive])
    {:ok, stat} = File.lstat(path)

    try do
      :ok = IO.binwrite(io, body)
      write_outputs!(rest, commit)
    rescue
      error ->
        if match?({:ok, %{inode: inode}} when inode == stat.inode, File.lstat(path)),
          do: File.rm(path)

        reraise error, __STACKTRACE__
    after
      File.close(io)
    end
  end

  defp replace_registry!(plan) do
    staged = plan.registry <> ".channel-#{System.unique_integer([:positive])}"
    File.write!(staged, plan.updated, [:exclusive])

    try do
      safe_path!(plan.root, Path.relative_to(plan.registry, plan.root))
      unchanged!(plan)
      File.rename!(staged, plan.registry)
    after
      File.rm(staged)
    end

    :ok
  end
end
