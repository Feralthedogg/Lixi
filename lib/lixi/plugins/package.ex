defmodule Lixi.Plugins.Package do
  @moduledoc "Verified, immutable BEAM packages staged by the server operator."
  @api_version 1
  @max_bytes 8_388_608
  @max_registry_bytes 8_388_608

  def api_version, do: @api_version

  def staging_root,
    do: Application.get_env(:lixi, :plugin_root, Path.join(data_root(), "plugins/staging"))

  defp data_root, do: Application.fetch_env!(:lixi, :data_dir) |> Path.expand()
  defp store_root, do: Path.join(data_root(), "plugins/artifacts")
  defp registry_path, do: Path.join(data_root(), "plugins/installed.json")

  def valid_id?(id),
    do: is_binary(id) and Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$/, id)

  def valid_entry?(name) do
    is_binary(name) and byte_size(name) <= 160 and
      Regex.match?(~r/^[A-Z][a-zA-Z0-9_]*(\.[A-Z][a-zA-Z0-9_]*)+$/, name) and
      not String.starts_with?(name, ["Lixi.", "Elixir.", "Mix.", "Kernel."])
  end

  def read(directory) do
    with :ok <- directory?(directory),
         {:ok, body} <- read_file(Path.join(directory, "manifest.json"), 65_536),
         {:ok, manifest} <- Jason.decode(body),
         :ok <- validate_manifest(manifest),
         {:ok, objects} <- read_objects(directory, manifest),
         true <-
           Enum.sum(Enum.map(objects, fn {_, _, binary} -> byte_size(binary) end)) <= @max_bytes do
      id = :crypto.hash(:sha256, :erlang.term_to_binary(manifest, [:deterministic]))
      id = Base.encode16(id, case: :lower)

      {:ok,
       %{id: id, manifest: manifest, objects: objects, manifest_body: Jason.encode!(manifest)}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_plugin_package}
    end
  end

  def validate_manifest(%{
        "schema" => 1,
        "apiVersion" => @api_version,
        "name" => name,
        "version" => version,
        "entry" => entry,
        "modules" => modules,
        "otp" => otp,
        "elixir" => elixir
      }) do
    cond do
      not Lixi.Plugin.valid_name?(name) or not Lixi.Plugin.valid_version?(version) or
          not valid_entry?(entry) ->
        {:error, :invalid_plugin_manifest}

      otp != System.otp_release() or elixir != elixir_version() ->
        {:error, :plugin_toolchain_mismatch}

      not is_list(modules) or length(modules) not in 1..16 ->
        {:error, :invalid_plugin_manifest}

      true ->
        :ok
    end
  end

  def validate_manifest(_), do: {:error, :invalid_plugin_manifest}
  def elixir_version, do: System.version() |> String.split(".") |> Enum.take(2) |> Enum.join(".")

  def staged(id) do
    with true <- valid_id?(id),
         root = Path.expand(staging_root()),
         :ok <- directory?(root),
         {:ok, package} <- read(Path.join(root, id)) do
      {:ok, package}
    else
      false -> {:error, :invalid_bundle_id}
      error -> error
    end
  end

  def install(package) do
    with {:ok, stored} <- store(package), :ok <- load(stored), do: {:ok, stored}
  end

  def restore(id) do
    with true <- is_binary(id) and Regex.match?(~r/^[a-f0-9]{64}$/, id),
         :ok <- safe_store_path(id),
         {:ok, package} <- read(Path.join(store_root(), id)),
         true <- package.id == id,
         :ok <- load(package) do
      {:ok, package}
    else
      _ -> {:error, :invalid_installed_package}
    end
  end

  def descriptor(package, config) do
    entry = package.manifest["entry"]

    module =
      Enum.find_value(package.objects, fn {module, _, _} ->
        if inspect(module) == entry, do: module
      end)

    case Lixi.Plugins.Call.evaluate(fn -> Lixi.Plugin.descriptor(module, config) end, 500) do
      {:ok, {:ok, descriptor}} ->
        if descriptor.name == package.manifest["name"] and
             descriptor.version == package.manifest["version"] do
          hashes =
            Enum.map(package.objects, fn {module, _, binary} ->
              {:ok, {^module, hash}} = :beam_lib.md5(binary)
              {module, hash}
            end)

          hash =
            :crypto.hash(
              :sha256,
              :erlang.term_to_binary({{:package, package.id}, config}, [:deterministic])
            )

          {:ok, Map.merge(descriptor, %{package: package.id, code_hashes: hashes, hash: hash})}
        else
          {:error, :plugin_metadata_mismatch}
        end

      {:ok, error} ->
        error

      error ->
        error
    end
  end

  def read_registry do
    with :ok <- safe_registry_parent(),
         {:ok, body} <- read_file(registry_path(), @max_registry_bytes),
         {:ok, %{"schema" => 1, "installed" => installed, "active" => active}} <-
           Jason.decode(body),
         true <-
           is_list(installed) and length(installed) <= 128 and is_list(active) and
             length(active) <= 32,
         true <- Enum.all?(installed, &valid_registry_entry?/1),
         true <-
           Enum.all?(active, fn entry ->
             is_map(entry) and Lixi.Plugin.valid_name?(entry["name"]) and
               Lixi.Plugin.valid_version?(entry["version"])
           end) do
      {:ok, %{installed: installed, active: active}}
    else
      {:error, :enoent} -> {:ok, %{installed: [], active: []}}
      _ -> {:error, :invalid_plugin_registry}
    end
  end

  def write_registry(versions, active) do
    installed =
      for {_, %{package: id} = desc} <- versions,
          do: %{package: id, config: desc.config}

    active =
      for {name, version} <- active,
          match?(%{package: _}, versions[{name, version}]),
          do: %{name: name, version: version}

    body = Jason.encode!(%{schema: 1, installed: installed, active: active})
    path = registry_path()

    with true <- byte_size(body) <= @max_registry_bytes,
         :ok <- ensure_directory(Path.join(data_root(), "plugins"), data_root()),
         :ok <- regular_or_missing?(path),
         :ok <- regular_or_missing?(path <> ".pending"),
         :ok <- write_private(path <> ".pending", body),
         :ok <- File.rename(path <> ".pending", path),
         do: :ok,
         else: (_ -> {:error, :plugin_registry_write_failed})
  end

  defp valid_registry_entry?(%{"package" => id, "config" => config}),
    do: is_binary(id) and Regex.match?(~r/^[a-f0-9]{64}$/, id) and is_map(config)

  defp valid_registry_entry?(_), do: false

  defp read_objects(directory, manifest) do
    entry = manifest["entry"]

    Enum.reduce_while(manifest["modules"], {:ok, []}, fn item, {:ok, objects} ->
      with true <- is_map(item),
           name when is_binary(name) <- item["module"],
           true <- name == entry or String.starts_with?(name, entry <> "."),
           true <- valid_entry?(name),
           hash when is_binary(hash) <- item["sha256"],
           path = Path.join(directory, "Elixir." <> name <> ".beam"),
           {:ok, binary} <- read_file(path, 4_194_304),
           true <- Base.encode16(:crypto.hash(:sha256, binary), case: :lower) == hash,
           {:ok, {module, chunks}} <- :beam_lib.chunks(binary, [:attributes, :exports]),
           true <- inspect(module) == name,
           false <- Keyword.has_key?(chunks[:attributes], :on_load),
           false <- Enum.any?(objects, fn {other, _, _} -> other == module end) do
        {:cont, {:ok, [{module, String.to_charlist(path), binary} | objects]}}
      else
        _ -> {:halt, {:error, :invalid_plugin_beam}}
      end
    end)
    |> case do
      {:ok, objects} ->
        if Enum.any?(objects, fn {module, _, _} -> inspect(module) == entry end),
          do: {:ok, objects},
          else: {:error, :plugin_entry_missing}

      error ->
        error
    end
  end

  defp store(package) do
    path = Path.join(store_root(), package.id)

    with :ok <- ensure_directory(path, data_root()),
         :ok <- write_objects(path, package),
         {:ok, stored} <- read(path),
         do: {:ok, stored}
  end

  defp write_objects(path, package) do
    files = [
      {"manifest.json", package.manifest_body}
      | Enum.map(package.objects, fn {module, _, binary} ->
          {Atom.to_string(module) <> ".beam", binary}
        end)
    ]

    Enum.reduce_while(files, :ok, fn {name, binary}, :ok ->
      file = Path.join(path, name)

      case read_file(file, @max_bytes) do
        {:ok, ^binary} ->
          {:cont, :ok}

        {:error, :enoent} ->
          with :ok <- regular_or_missing?(file <> ".pending"),
               :ok <- File.write(file <> ".pending", binary, [:sync]),
               :ok <- File.rename(file <> ".pending", file),
               do: {:cont, :ok},
               else: (_ -> {:halt, {:error, :package_store_failed}})

        _ ->
          {:halt, {:error, :package_store_conflict}}
      end
    end)
  end

  defp load(package) do
    Enum.reduce_while(package.objects, {:ok, []}, fn {module, path, binary} = object,
                                                     {:ok, unloaded} ->
      case {:code.is_loaded(module), :code.which(module)} do
        {false, :non_existing} ->
          {:cont, {:ok, [object | unloaded]}}

        {false, ^path} ->
          {:cont, {:ok, [object | unloaded]}}

        {{:file, ^path}, ^path} ->
          {:ok, {^module, hash}} = :beam_lib.md5(binary)

          if module.module_info(:md5) == hash,
            do: {:cont, {:ok, unloaded}},
            else: {:halt, {:error, :plugin_module_conflict}}

        _ ->
          {:halt, {:error, :plugin_module_conflict}}
      end
    end)
    |> case do
      {:ok, []} ->
        :ok

      {:ok, objects} ->
        with {:ok, prepared} <- :code.prepare_loading(objects),
             :ok <- :code.finish_loading(prepared),
             do: :ok,
             else: (_ -> {:error, :plugin_code_load_failed})

      error ->
        error
    end
  end

  defp write_private(path, body) do
    case File.open(path, [:write, :binary], fn device ->
           with :ok <- File.chmod(path, 0o600),
                :ok <- IO.binwrite(device, body),
                :ok <- :file.sync(device),
                do: :ok
         end) do
      {:ok, :ok} -> :ok
      _ -> {:error, :plugin_registry_write_failed}
    end
  end

  defp read_file(path, limit) do
    with {:ok, %{type: :regular, size: size}} <- File.lstat(path),
         true <- size <= limit,
         {:ok, body} <- File.read(path),
         do: {:ok, body},
         else: (
           {:error, reason} -> {:error, reason}
           _ -> {:error, :invalid_plugin_file}
         )
  end

  defp directory?(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_plugin_directory}
    end
  end

  defp regular_or_missing?(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      _ -> {:error, :invalid_plugin_file}
    end
  end

  defp ensure_directory(path, root) do
    case File.lstat(root) do
      {:error, :enoent} -> File.mkdir_p(root)
      _ -> :ok
    end

    with :ok <- directory?(root) do
      Path.relative_to(path, root)
      |> Path.split()
      |> Enum.reduce_while({:ok, root}, fn segment, {:ok, parent} ->
        next = Path.join(parent, segment)

        case File.mkdir(next) do
          :ok ->
            {:cont, {:ok, next}}

          {:error, :eexist} ->
            if directory?(next) == :ok,
              do: {:cont, {:ok, next}},
              else: {:halt, {:error, :invalid_plugin_directory}}

          _ ->
            {:halt, {:error, :package_store_failed}}
        end
      end)
      |> case do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end

  defp safe_store_path(id),
    do:
      check_directories([
        data_root(),
        Path.join(data_root(), "plugins"),
        store_root(),
        Path.join(store_root(), id)
      ])

  defp safe_registry_parent,
    do: check_directories([data_root(), Path.join(data_root(), "plugins")])

  defp check_directories(paths),
    do:
      Enum.reduce_while(paths, :ok, fn path, :ok ->
        case directory?(path) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
end
