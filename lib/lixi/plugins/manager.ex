defmodule Lixi.Plugins.Manager do
  @moduledoc "Immutable version catalogue and request leases; installed code is never purged in use."
  use GenServer
  alias Lixi.Plugins.Package
  @snapshot {__MODULE__, :catalogue}
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__, timeout: 120_000)

  def install(module, config) do
    case Lixi.Plugins.Call.evaluate(fn -> Lixi.Plugin.descriptor(module, config) end, 500) do
      {:ok, {:ok, descriptor}} -> GenServer.call(__MODULE__, {:install, descriptor})
      {:ok, error} -> error
      error -> error
    end
  end

  def install_package(id, config),
    do: GenServer.call(__MODULE__, {:install_package, id, config}, 30_000)

  def activate_local(descriptor), do: GenServer.call(__MODULE__, {:activate, descriptor})
  def deactivate_local(name), do: GenServer.call(__MODULE__, {:deactivate, name})
  def recover, do: GenServer.call(__MODULE__, :recover)
  def status, do: GenServer.call(__MODULE__, :status)
  def remove(name, version), do: GenServer.call(__MODULE__, {:remove, {name, version}})
  def catalogue, do: GenServer.call(__MODULE__, :catalogue)

  def checkout(name, version) do
    case GenServer.call(__MODULE__, {:checkout, {name, version}, self()}) do
      {:ok, lease, descriptor} ->
        Registry.register(Lixi.Registry, {:plugin_lease, lease}, descriptor)
        {:ok, lease, descriptor}

      error ->
        error
    end
  end

  def checkin(lease) do
    Registry.unregister(Lixi.Registry, {:plugin_lease, lease})
    GenServer.cast(__MODULE__, {:checkin, lease})
  end

  @impl true
  def init(_) do
    snapshot = :persistent_term.get(@snapshot, :undefined)

    memory =
      case snapshot do
        :undefined ->
          %{versions: %{}, active: %{}}

        %{versions: versions, active: active} ->
          %{versions: versions, active: active}

        versions ->
          %{versions: versions, active: %{}}
      end

    # Disk is authoritative for packages even if the installer died before updating its snapshot.
    restored = restore_packages()
    legacy = Map.reject(memory.versions, fn {_, desc} -> Map.has_key?(desc, :package) end)

    active =
      Map.filter(memory.active, fn {name, version} -> Map.has_key?(legacy, {name, version}) end)

    state = %{
      restored
      | versions: Map.merge(legacy, restored.versions),
        active: Map.merge(active, restored.active)
    }

    state = Map.merge(state, %{pending: nil, recovery_timer: nil})

    if not Lixi.Cluster.Coordinator.enabled?() do
      for {name, version} <- active, not Map.has_key?(restored.active, name) do
        :ok =
          Lixi.Cluster.Coordinator.command(
            {:activate_plugin, Lixi.Plugin.public(legacy[{name, version}])}
          )
      end
    end

    leases =
      Registry.select(Lixi.Registry, [
        {{{:plugin_lease, :"$1"}, :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
      ])

    state =
      Enum.reduce(leases, state, fn {lease, owner, desc}, state ->
        put_in(state, [:leases, lease], %{
          owner: owner,
          key: {desc.name, desc.version},
          monitor: Process.monitor(owner)
        })
      end)

    state = if snapshot == :undefined, do: install_configured(state), else: state
    persist(state)
    {:ok, state}
  end

  defp restore_packages do
    with {:ok, registry} <- Package.read_registry() do
      state =
        Enum.reduce(registry.installed, %{versions: %{}, active: %{}, leases: %{}}, fn entry,
                                                                                       state ->
          with {:ok, package} <- Package.restore(entry["package"]),
               {:ok, desc} <- Package.descriptor(package, entry["config"]),
               {:ok, state} <- add_version(state, desc) do
            state
          else
            _ -> raise ArgumentError, "Installed plugin package cannot be restored"
          end
        end)

      if Lixi.Cluster.Coordinator.enabled?() do
        state
      else
        desired = Map.new(registry.active, &{&1["name"], &1["version"]})
        {:ok, current} = Lixi.Cluster.Coordinator.query(:plugins)

        for {name, %{package: _} = desc} <- current,
            desired[name] != desc.version,
            do: :ok = Lixi.Cluster.Coordinator.command({:deactivate_plugin, name})

        Enum.reduce(registry.active, state, fn entry, state ->
          desc = state.versions[{entry["name"], entry["version"]}]
          if desc == nil, do: raise(ArgumentError, "Active plugin package is not installed")
          :ok = Lixi.Cluster.Coordinator.command({:activate_plugin, Lixi.Plugin.public(desc)})
          %{state | active: Map.put(state.active, desc.name, desc.version)}
        end)
      end
    else
      _ -> raise ArgumentError, "Plugin package registry cannot be read"
    end
  end

  defp install_configured(state) do
    configured = configured_plugins()

    if length(configured) > 32,
      do: raise(ArgumentError, "At most 32 initial plugins are supported")

    Enum.reduce(configured, state, fn {module, config}, state ->
      with {:ok, {:ok, desc}} <-
             Lixi.Plugins.Call.evaluate(fn -> Lixi.Plugin.descriptor(module, config) end, 500),
           {:ok, state} <- add_version(state, desc) do
        if not Lixi.Cluster.Coordinator.enabled?() and not Map.has_key?(state.active, desc.name) do
          :ok = Lixi.Cluster.Coordinator.command({:activate_plugin, Lixi.Plugin.public(desc)})
          %{state | active: Map.put(state.active, desc.name, desc.version)}
        else
          state
        end
      else
        _ -> raise ArgumentError, "Invalid initial plugin"
      end
    end)
  end

  defp configured_plugins do
    case Application.get_env(:lixi, :plugin_boot_file) do
      nil ->
        Application.get_env(:lixi, :plugins, [])

      file ->
        allowed = Application.get_env(:lixi, :plugin_modules, [])
        {:ok, %{type: :regular, size: size}} = File.lstat(file)
        if size > 65_536, do: raise(ArgumentError, "Plugin configuration exceeds 64 KiB")
        values = file |> File.read!() |> Jason.decode!()

        unless is_list(values) and length(values) <= 32,
          do: raise(ArgumentError, "Invalid plugin configuration")

        Enum.map(values, fn entry ->
          module = if is_map(entry), do: Enum.find(allowed, &(inspect(&1) == entry["module"]))

          unless module && is_map(entry["config"]),
            do: raise(ArgumentError, "Plugin module/configuration is not allowed")

          {module, entry["config"]}
        end)
    end
  end

  @impl true
  def handle_call(:catalogue, _, state),
    do: {:reply, Enum.map(state.versions, fn {_, desc} -> Lixi.Plugin.public(desc) end), state}

  def handle_call(:status, _, state),
    do: {:reply, %{recovery_required: state.pending != nil}, state}

  def handle_call(:recover, _, state) do
    case recover_activation(state) do
      {:ok, next} -> {:reply, :ok, next}
      {:error, next} -> {:reply, {:error, :plugin_recovery_required}, next}
    end
  end

  def handle_call(message, _, %{pending: pending} = state)
      when pending != nil and is_tuple(message) and
             elem(message, 0) in [:install, :install_package, :activate, :deactivate, :remove],
      do: {:reply, {:error, :plugin_recovery_required}, state}

  def handle_call({:install, desc}, _, state), do: install_version(state, desc)

  def handle_call({:install_package, id, config}, _, state) do
    with {:ok, package} <- Package.staged(id),
         :ok <- admit_package(state, package, config),
         {:ok, package} <- Package.install(package),
         {:ok, desc} <- Package.descriptor(package, config) do
      install_version(state, desc)
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:activate, desc}, _, state) do
    case state.versions[{desc.name, desc.version}] do
      %{hash: hash} when hash == desc.hash ->
        next = %{state | active: Map.put(state.active, desc.name, desc.version)}
        change_activation(next, state, {:activate_plugin, desc})

      _ ->
        {:reply, {:error, :plugin_not_installed}, state}
    end
  end

  def handle_call({:deactivate, name}, _, state),
    do:
      change_activation(
        %{state | active: Map.delete(state.active, name)},
        state,
        {:deactivate_plugin, name}
      )

  def handle_call({:remove, key}, _, state) do
    cond do
      Enum.any?(state.leases, fn {_, lease} -> lease.key == key end) ->
        {:reply, {:error, :plugin_in_use}, state}

      state.active[elem(key, 0)] == elem(key, 1) ->
        {:reply, {:error, :plugin_active}, state}

      true ->
        next = %{state | versions: Map.delete(state.versions, key)}

        case save_registry(next, state) do
          :ok ->
            persist(next)
            notify_member()
            {:reply, :ok, next}

          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:checkout, key, owner}, _, state) do
    case state.versions[key] do
      nil ->
        {:reply, {:error, :plugin_not_installed}, state}

      desc when map_size(state.leases) < 1024 ->
        lease = make_ref()

        state =
          put_in(state, [:leases, lease], %{
            owner: owner,
            key: key,
            monitor: Process.monitor(owner)
          })

        {:reply, {:ok, lease, desc}, state}

      _ ->
        {:reply, {:error, :plugin_capacity}, state}
    end
  end

  defp admit_package(state, package, config) do
    manifest = package.manifest
    key = {manifest["name"], manifest["version"]}
    existing = state.versions[key]

    cond do
      not is_map(config) ->
        {:error, :invalid_plugin_config}

      existing && (Map.get(existing, :package) != package.id or existing.config != config) ->
        {:error, :version_conflict}

      existing != nil ->
        :ok

      map_size(state.versions) >= 128 ->
        {:error, :plugin_capacity}

      Enum.count(state.versions, fn {{name, _}, _} -> name == elem(key, 0) end) >= 4 ->
        {:error, :version_capacity}

      true ->
        case Jason.encode(config) do
          {:ok, body} when byte_size(body) <= 65_536 -> :ok
          _ -> {:error, :invalid_plugin_config}
        end
    end
  end

  defp install_version(state, desc) do
    with {:ok, next} <- add_version(state, desc), :ok <- save_registry(next, state) do
      persist(next)
      notify_member()
      {:reply, {:ok, Lixi.Plugin.public(desc)}, next}
    else
      error -> {:reply, error, state}
    end
  end

  defp add_version(state, desc) do
    key = {desc.name, desc.version}
    existing = state.versions[key]

    cond do
      existing && existing != desc ->
        {:error, :version_conflict}

      Enum.any?(state.versions, fn {other_key, other} ->
        other.module == desc.module and other_key != key
      end) ->
        {:error, :module_reused}

      map_size(state.versions) >= 128 and existing == nil ->
        {:error, :plugin_capacity}

      Enum.count(state.versions, fn {{name, _}, _} -> name == desc.name end) >= 4 and
          existing == nil ->
        {:error, :version_capacity}

      true ->
        {:ok, %{state | versions: Map.put(state.versions, key, desc)}}
    end
  end

  defp change_activation(next, state, command) do
    case Lixi.Cluster.Coordinator.query(:plugins) do
      {:ok, current} ->
        name = elem(command, 1)
        name = if is_map(name), do: name.name, else: name

        previous =
          if desc = current[name], do: {:activate_plugin, desc}, else: {:deactivate_plugin, name}

        case Lixi.Cluster.Coordinator.command(command) do
          :ok ->
            case save_registry(next, state) do
              :ok ->
                persist(next)
                notify_member()
                {:reply, :ok, next}

              error ->
                compensate_activation(state, previous, error)
            end

          {:error, :unavailable} = error ->
            compensate_activation(state, previous, error)

          error ->
            {:reply, error, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  defp compensate_activation(state, command, error) do
    case recover_activation(%{state | pending: command}) do
      {:ok, next} -> {:reply, error, next}
      {:error, next} -> {:reply, {:error, :plugin_recovery_required}, next}
    end
  end

  defp recover_activation(%{pending: nil} = state), do: {:ok, state}

  defp recover_activation(state) do
    case Lixi.Cluster.Coordinator.command(state.pending) do
      :ok ->
        if state.recovery_timer, do: Process.cancel_timer(elem(state.recovery_timer, 1))
        {:ok, %{state | pending: nil, recovery_timer: nil}}

      _ ->
        if state.recovery_timer do
          {:error, state}
        else
          generation = make_ref()
          timer = Process.send_after(self(), {:recover_activation, generation}, 250)
          {:error, %{state | recovery_timer: {generation, timer}}}
        end
    end
  end

  defp save_registry(next, previous) do
    if registry_state(next) == registry_state(previous),
      do: :ok,
      else: Package.write_registry(next.versions, next.active)
  end

  defp registry_state(state) do
    packages = Map.filter(state.versions, fn {_, desc} -> Map.has_key?(desc, :package) end)

    active =
      Map.filter(state.active, fn {name, version} -> Map.has_key?(packages, {name, version}) end)

    {packages, active}
  end

  @impl true
  def handle_cast({:checkin, lease}, state), do: {:noreply, release(state, lease)}
  @impl true
  def handle_info({:recover_activation, generation}, %{recovery_timer: {generation, _}} = state) do
    case recover_activation(%{state | recovery_timer: nil}) do
      {:ok, next} -> {:noreply, next}
      {:error, next} -> {:noreply, next}
    end
  end

  def handle_info({:recover_activation, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, _, _, _}, state) do
    leases = for {id, lease} <- state.leases, lease.monitor == ref, do: id
    {:noreply, Enum.reduce(leases, state, &release(&2, &1))}
  end

  defp release(state, id) do
    case Map.pop(state.leases, id) do
      {nil, _} ->
        state

      {lease, leases} ->
        Process.demonitor(lease.monitor, [:flush])
        %{state | leases: leases}
    end
  end

  defp persist(state), do: :persistent_term.put(@snapshot, Map.take(state, [:versions, :active]))

  defp notify_member do
    if pid = Process.whereis(Lixi.Cluster.Member), do: send(pid, :heartbeat)
  end

  @impl true
  def code_change(_, state, _),
    do:
      {:ok,
       state
       |> Map.put_new(:active, %{})
       |> Map.put_new(:pending, nil)
       |> Map.put_new(:recovery_timer, nil)}
end
