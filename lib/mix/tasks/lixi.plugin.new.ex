defmodule Mix.Tasks.Lixi.Plugin.New do
  use Mix.Task
  @shortdoc "Creates a BEAM plugin source template"

  @impl true
  def run(arguments) do
    {options, names, invalid} =
      OptionParser.parse(arguments, strict: [module: :string, output: :string])

    unless invalid == [] and match?([_], names),
      do: Mix.raise("Usage: mix lixi.plugin.new NAME [--module MyPlugin.V1] [--output DIRECTORY]")

    Mix.Task.run("compile")
    [name] = names
    module = options[:module] || Macro.camelize(String.replace(name, "-", "_")) <> "Plugin.V1"

    unless Lixi.Plugin.valid_name?(name) and Lixi.Plugins.Package.valid_entry?(module),
      do: Mix.raise("Invalid plugin name or versioned module namespace")

    output = Path.expand(options[:output] || Path.join("plugins", name))
    File.mkdir_p!(Path.dirname(output))

    case File.mkdir(output) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("Cannot create a new plugin directory: #{reason}")
    end

    File.mkdir!(Path.join(output, "lib"))
    project = %{schema: 1, apiVersion: 1, name: name, version: "1.0.0", entry: module}

    File.write!(Path.join(output, "plugin.json"), Jason.encode!(project, pretty: true) <> "\n", [
      :exclusive
    ])

    File.write!(Path.join(output, "lib/plugin.ex"), source(name, module), [:exclusive])

    File.write!(
      Path.join(output, "config.example.json"),
      Jason.encode!(%{tracks: %{demo: "https://media.example/demo.mp3"}}, pretty: true) <> "\n",
      [:exclusive]
    )

    File.write!(
      Path.join(output, "README.md"),
      """
      # #{name}

      Elixir/BEAM plugin for Lixi plugin API v1. Edit `lib/plugin.ex` and `plugin.json` together.
      Use a new module namespace for every version (for example `#{module}Next`).

      From the Lixi server source directory:

      ```sh
      mix lixi.plugin.pack "#{Path.relative_to_cwd(output)}" --output /existing/staging/#{name}-1.0.0
      ```

      Stage that directory under the server's `LIXI_PLUGIN_ROOT`, then POST
      `/v4/lixi/plugins/packages` with `{"bundle":"#{name}-1.0.0","config":{"tracks":{}}}`.
      Activate `#{name}` version `1.0.0` with the management API. Source identifiers
      use `#{name}:demo`; `GET /v4/plugins/#{name}/health` reports the configured track count.
      Media paths and HTTP hosts must be allowed by the server's source settings.
      """,
      [:exclusive]
    )

    Mix.shell().info("Plugin created: #{output}")
  end

  defp source(name, module) do
    """
    defmodule #{module} do
      @behaviour Lixi.Plugin
      @impl true
      def metadata, do: %{name: "#{name}", version: "1.0.0", sources: ["#{name}:"]}

      @impl true
      def load("#{name}:" <> key, config) do
        case get_in(config, ["tracks", key]) do
          uri when is_binary(uri) -> Lixi.Sources.load_builtin(uri)
          _ -> %{"loadType" => "empty", "data" => nil}
        end
      end

      @impl true
      def request(%{method: "GET", path: ["health"]}, config) do
        {:ok, 200, %{name: "#{name}", version: "1.0.0", tracks: map_size(Map.get(config, "tracks", %{}))}}
      end
      def request(_, _), do: {:ok, 404, %{error: "Plugin route not found"}}
    end
    """
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end
end
