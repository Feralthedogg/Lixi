defmodule Mix.Tasks.Lixi.Bundle do
  use Mix.Task
  @shortdoc "Creates a compatible hot-patch bundle from compiled BEAM files"

  @impl true
  def run(arguments) do
    {options, rest, invalid} =
      OptionParser.parse(arguments,
        strict: [from: :string, to: :string, output: :string, modules: :string, defaults: :string]
      )

    if rest != [] or invalid != [], do: Mix.raise("Invalid bundle arguments")
    Mix.Task.run("compile")
    from = required(options, :from)
    target = required(options, :to)
    output = required(options, :output) |> Path.expand()
    names = required(options, :modules) |> String.split(",", trim: true) |> Enum.uniq()
    allowed = Lixi.Upgrade.status().supported_modules

    if names == [] or Enum.any?(names, &(&1 not in allowed)),
      do:
        Mix.raise("Only supported hot-patch modules can be bundled: #{Enum.join(allowed, ", ")}")

    defaults =
      if path = options[:defaults], do: path |> File.read!() |> Jason.decode!(), else: %{}

    objects =
      Enum.map(names, fn name ->
        filename = "Elixir.#{name}.beam"
        {name, filename, File.read!(Path.join(Mix.Project.compile_path(), filename))}
      end)

    manifest = %{
      schema: 1,
      from: from,
      to: target,
      stateDefaults: defaults,
      modules:
        Enum.map(objects, fn {name, _, bytes} ->
          %{module: name, sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
        end)
    }

    case File.mkdir(output) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("Cannot create a new bundle directory: #{reason}")
    end

    paths =
      Enum.map(objects, fn {_, file, bytes} ->
        path = Path.join(output, file)
        File.write!(path, bytes, [:exclusive])
        path
      end)

    manifest_path = Path.join(output, "manifest.json")
    File.write!(manifest_path, Jason.encode!(manifest, pretty: true), [:exclusive])

    case Lixi.Upgrade.read_bundle(output) do
      {:ok, _} ->
        Mix.shell().info("Bundle created: #{output} (#{from} -> #{target})")

      {:error, reason} ->
        Enum.each([manifest_path | paths], &File.rm!/1)
        File.rmdir!(output)
        Mix.raise("Bundle validation failed: #{reason}")
    end
  end

  defp required(options, key),
    do: options[key] || Mix.raise("--#{key} is required")
end
