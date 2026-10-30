defmodule Mix.Tasks.Lixi.Plugin.Pack do
  use Mix.Task
  alias Lixi.Plugins.Package
  @shortdoc "Compiles and verifies a plugin package in a separate BEAM VM"

  @impl true
  def run(arguments) do
    {options, projects, invalid} = OptionParser.parse(arguments, strict: [output: :string])

    unless invalid == [] and match?([_], projects) and options[:output],
      do: Mix.raise("Usage: mix lixi.plugin.pack PROJECT --output NEW_DIRECTORY")

    Mix.Task.run("compile")
    project_root = hd(projects) |> Path.expand()
    {:ok, %{type: :directory}} = File.lstat(project_root)
    project = read_project(project_root)
    sources = Path.wildcard(Path.join(project_root, "lib/**/*.ex"))

    if length(sources) not in 1..16,
      do: Mix.raise("A plugin must contain 1 to 16 Elixir source files")

    Enum.each(sources, &validate_source!(&1, project_root))
    output = Path.expand(options[:output])
    File.mkdir_p!(Path.dirname(output))

    case File.mkdir(output) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("Cannot create a new package directory: #{reason}")
    end

    try do
      compile!(sources, output, project["entry"])
      metadata_path = Path.join(output, ".metadata.json")
      metadata = metadata_path |> File.read!() |> Jason.decode!()
      File.rm!(metadata_path)

      unless metadata["name"] == project["name"] and metadata["version"] == project["version"],
        do: Mix.raise("Plugin metadata does not match plugin.json")

      objects = Path.wildcard(Path.join(output, "*.beam"))

      modules =
        Enum.map(objects, fn file ->
          %{
            module: file |> Path.basename(".beam") |> String.trim_leading("Elixir."),
            sha256: Base.encode16(:crypto.hash(:sha256, File.read!(file)), case: :lower)
          }
        end)

      manifest =
        Map.merge(project, %{
          "modules" => modules,
          "otp" => System.otp_release(),
          "elixir" => Package.elixir_version()
        })

      File.write!(
        Path.join(output, "manifest.json"),
        Jason.encode!(manifest, pretty: true) <> "\n",
        [:exclusive]
      )

      case Package.read(output) do
        {:ok, package} -> Mix.shell().info("Plugin package created: #{output} (#{package.id})")
        {:error, reason} -> Mix.raise("Invalid plugin package: #{reason}")
      end
    rescue
      exception ->
        cleanup_generated(output)
        reraise exception, __STACKTRACE__
    end
  end

  defp read_project(root) do
    path = Path.join(root, "plugin.json")
    {:ok, %{type: :regular, size: size}} = File.lstat(path)
    if size > 65_536, do: Mix.raise("plugin.json exceeds 64 KiB")
    project = path |> File.read!() |> Jason.decode!()

    manifest =
      if is_map(project),
        do:
          Map.merge(project, %{
            "otp" => System.otp_release(),
            "elixir" => Package.elixir_version(),
            "modules" => [%{}]
          })

    unless Package.validate_manifest(manifest) == :ok, do: Mix.raise("Invalid plugin.json")
    Map.take(project, ~w(schema apiVersion name version entry))
  end

  defp validate_source!(file, root) do
    parts = file |> Path.relative_to(root) |> Path.split()

    Enum.reduce(parts, root, fn part, parent ->
      path = Path.join(parent, part)
      {:ok, %{type: type, size: size}} = File.lstat(path)

      unless type in [:directory, :regular] and (type == :directory or size <= 1_048_576),
        do: Mix.raise("Plugin sources must be regular files of at most 1 MiB")

      path
    end)
  end

  defp compile!(sources, output, entry) do
    paths = :code.get_path() |> Enum.flat_map(&["-pa", List.to_string(&1)])

    script = """
    [destination, entry | sources] = System.argv()
    case Kernel.ParallelCompiler.compile_to_path(sources, destination, return_diagnostics: true) do
      {:ok, _, _} -> :ok
      {:error, diagnostics, _} ->
        for diagnostic <- diagnostics, do: IO.puts(:stderr, diagnostic.message)
        System.halt(1)
    end
    Code.prepend_path(destination)
    module = String.to_existing_atom("Elixir." <> entry)
    task = Task.async(fn -> Lixi.Plugin.descriptor(module, %{}) end)
    case Task.yield(task, 500) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, descriptor}} ->
        File.write!(Path.join(destination, ".metadata.json"), Jason.encode!(Map.take(descriptor, [:name, :version])))
      _ ->
        IO.puts(:stderr, "Plugin metadata failed or exceeded 500 ms")
        System.halt(1)
    end
    """

    case System.cmd(
           System.find_executable("elixir"),
           ["--erl", "+S 2:2"] ++ paths ++ ["-e", script, output, entry | sources],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {message, _} -> Mix.raise("Plugin compilation failed:\n" <> message)
    end
  end

  defp cleanup_generated(output) do
    for file <- File.ls!(output),
        file in [".metadata.json", "manifest.json"] or String.ends_with?(file, ".beam") do
      path = Path.join(output, file)
      if match?({:ok, %{type: :regular}}, File.lstat(path)), do: File.rm(path)
    end

    File.rmdir(output)
  end
end
