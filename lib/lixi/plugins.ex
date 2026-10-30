defmodule Lixi.Plugins do
  alias Lixi.Cluster.Coordinator
  alias Lixi.Plugins.{Call, Manager}
  def install(module, config \\ %{}), do: Manager.install(module, config)
  def install_package(id, config \\ %{}), do: Manager.install_package(id, config)

  def active do
    case Coordinator.query(:plugins) do
      {:ok, plugins} -> {:ok, plugins}
      error -> error
    end
  end

  def activate(name, version) do
    with {:ok, instances} <- Lixi.Cluster.instances() do
      versions =
        instances
        |> Enum.reject(fn {instance, _} -> instance == node() end)
        |> Enum.flat_map(fn {_, info} -> Map.get(info, :plugins, []) end)

      matches =
        Enum.filter(versions ++ Manager.catalogue(), &(&1.name == name and &1.version == version))
        |> Enum.uniq_by(& &1.hash)

      case matches do
        [] ->
          {:error, :plugin_not_installed}

        [descriptor] ->
          if Coordinator.enabled?(),
            do: Coordinator.command({:activate_plugin, descriptor}),
            else: Manager.activate_local(descriptor)

        _ ->
          {:error, :artifact_conflict}
      end
    end
  end

  def deactivate(name),
    do:
      if(Coordinator.enabled?(),
        do: Coordinator.command({:deactivate_plugin, name}),
        else: Manager.deactivate_local(name)
      )

  def remove(name, version) do
    with {:ok, plugins} <- active() do
      if match?(%{version: ^version}, plugins[name]),
        do: {:error, :plugin_active},
        else: Manager.remove(name, version)
    end
  end

  def load(identifier) do
    with {:ok, plugins} <- active() do
      plugin =
        plugins
        |> Map.values()
        |> Enum.filter(fn desc ->
          Enum.any?(desc.sources, &String.starts_with?(identifier, &1))
        end)
        |> Enum.max_by(
          fn desc ->
            desc.sources
            |> Enum.filter(&String.starts_with?(identifier, &1))
            |> Enum.map(&byte_size/1)
            |> Enum.max()
          end,
          fn -> nil end
        )

      if plugin do
        with {:ok, result} <- invoke(plugin, :load, [identifier]),
             :ok <- validate_result(result),
             do: {:ok, result}
      else
        :unhandled
      end
    end
  end

  def request(name, request) do
    with {:ok, plugins} <- active(), descriptor when not is_nil(descriptor) <- plugins[name] do
      invoke(descriptor, :request, [request])
    else
      nil -> {:error, :plugin_not_found}
      error -> error
    end
  end

  defp invoke(desc, function, args) do
    local =
      Enum.any?(
        Manager.catalogue(),
        &(&1.name == desc.name and &1.version == desc.version and &1.hash == desc.hash)
      )

    local_result =
      if local,
        do: invoke_local(desc.name, desc.version, desc.hash, function, args),
        else: {:error, :plugin_not_installed}

    if retryable?(local_result, function, args) do
      with {:ok, instances} <- Lixi.Cluster.instances() do
        instances
        |> Enum.filter(fn {instance, info} ->
          instance != node() and info.status == :accepting and
            Enum.any?(
              Map.get(info, :plugins, []),
              &(&1.name == desc.name and &1.version == desc.version and &1.hash == desc.hash)
            )
        end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.reduce_while({:error, :plugin_unavailable}, fn {instance, _}, _ ->
          result =
            Lixi.Cluster.rpc(instance, __MODULE__, :invoke_local, [
              desc.name,
              desc.version,
              desc.hash,
              function,
              args
            ])

          if retryable?(result, function, args), do: {:cont, result}, else: {:halt, result}
        end)
      end
    else
      local_result
    end
  end

  defp retryable?({:error, reason}, _, _)
       when reason in [:plugin_not_installed, :plugin_capacity, :plugin_unavailable], do: true

  defp retryable?({:error, :unavailable}, :load, _), do: true

  defp retryable?({:error, :unavailable}, :request, [%{method: method}]),
    do: method in ["GET", "HEAD", "OPTIONS"]

  defp retryable?(_, _, _), do: false

  def invoke_local(name, version, hash, function, args)
      when function in [:load, :request] do
    with {:ok, lease, descriptor} <- Manager.checkout(name, version) do
      try do
        if descriptor.hash == hash and
             function_exported?(descriptor.module, function, length(args) + 1) do
          Call.run(descriptor, function, args)
        else
          {:error, :unsupported_plugin_callback}
        end
      after
        Manager.checkin(lease)
      end
    end
  end

  def info do
    case active() do
      {:ok, plugins} -> Enum.map(plugins, fn {_, d} -> %{name: d.name, version: d.version} end)
      _ -> []
    end
  end

  defp validate_result(%{"loadType" => type, "data" => data} = result) do
    valid =
      case type do
        "track" ->
          valid_track?(data)

        "search" ->
          is_list(data) and length(data) <= 100 and Enum.all?(data, &valid_track?/1)

        "playlist" ->
          is_map(data) and is_map(data["info"]) and is_list(data["tracks"]) and
            length(data["tracks"]) <= 100 and Enum.all?(data["tracks"], &valid_track?/1)

        "empty" ->
          data == nil

        "error" ->
          is_map(data) and is_binary(data["message"]) and
            data["severity"] in ["common", "suspicious", "fault"]

        _ ->
          false
      end

    with true <- valid,
         {:ok, body} <- Jason.encode(result),
         true <- byte_size(body) <= 262_144,
         do: :ok,
         else: (_ -> {:error, :invalid_plugin_result})
  end

  defp validate_result(_), do: {:error, :invalid_plugin_result}

  defp valid_track?(%{
         "encoded" => encoded,
         "info" => info,
         "pluginInfo" => plugin,
         "userData" => user
       }) do
    is_map(plugin) and is_map(user) and
      case Lixi.Track.decode(encoded) do
        {:ok, track} -> track["info"] == info
        _ -> false
      end
  end

  defp valid_track?(_), do: false
end
