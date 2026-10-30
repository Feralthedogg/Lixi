defmodule Lixi.Cluster.Machine do
  @moduledoc "Replicated ownership metadata. Uncertain network loss never releases a sender."
  @behaviour :ra_machine

  @impl true
  def init(config),
    do: %{
      names: %{},
      instances: %{},
      keys: %{},
      plugins: %{},
      limit: Map.get(config, :limit, 100_000)
    }

  @impl true
  def apply(meta, command, state) do
    state = Map.put(state, :revision, Map.get(meta, :index, 0))
    {state, reply, effects} = execute(command, state, Map.get(meta, :index, 0))

    effects =
      if meta[:index] && meta.index > 0 && rem(meta.index, 128) == 0,
        do: effects ++ [{:release_cursor, meta.index, state}],
        else: effects

    {state, reply, effects}
  end

  defp execute({:claim, key, owner}, state, index) when is_pid(owner) do
    case state.names[key] do
      %{owner: ^owner} = entry ->
        {state, {:ok, entry}, []}

      nil when map_size(state.names) < state.limit ->
        entry = %{owner: owner, token: index}
        {put_in(state, [:names, key], entry), {:ok, entry}, [{:monitor, :process, owner}]}

      nil ->
        {state, {:error, :capacity}, []}

      _ ->
        {state, {:error, :owned}, []}
    end
  end

  defp execute({:release, key, owner}, state, _) do
    case state.names[key] do
      %{owner: ^owner} -> {%{state | names: Map.delete(state.names, key)}, :ok, []}
      _ -> {state, :ok, []}
    end
  end

  defp execute({:move, key, old, new}, state, index) when is_pid(new) do
    case state.names[key] do
      %{owner: ^old} ->
        entry = %{owner: new, token: index}
        {put_in(state, [:names, key], entry), :ok, [{:monitor, :process, new}]}

      %{owner: ^new} ->
        {state, :ok, []}

      _ ->
        {state, {:error, :owner_changed}, []}
    end
  end

  defp execute({:begin_move, key, old, new, expected, reference}, state, index)
       when is_pid(new) do
    case state.names[key] do
      %{owner: ^old, token: ^expected} ->
        entry = %{owner: new, backup: old, token: index, move_ref: reference}
        {put_in(state, [:names, key], entry), {:ok, entry}, [{:monitor, :process, new}]}

      %{owner: ^new, move_ref: ^reference} = entry ->
        {state, {:ok, entry}, []}

      _ ->
        {state, {:error, :owner_changed}, []}
    end
  end

  defp execute({:finish_move, key, owner, reference}, state, _) do
    case state.names[key] do
      %{owner: ^owner, move_ref: ^reference} = entry ->
        entry = entry |> Map.drop([:backup, :move_ref]) |> Map.put(:completed_move, reference)
        {put_in(state, [:names, key], entry), :ok, []}

      %{owner: ^owner, completed_move: ^reference} ->
        {state, :ok, []}

      _ ->
        {state, {:error, :owner_changed}, []}
    end
  end

  defp execute({:abort_move, key, source, target, expected, reference}, state, index) do
    case state.names[key] do
      %{owner: ^source, token: ^expected} ->
        {put_in(state, [:names, key], %{owner: source, token: index}), :ok, []}

      %{owner: ^target, backup: ^source, move_ref: ^reference} ->
        {put_in(state, [:names, key], %{owner: source, token: index}), :ok, []}

      _ ->
        {state, {:error, :owner_changed}, []}
    end
  end

  defp execute({:instance, instance, info}, state, _) do
    if map_size(state.instances) < 64 or Map.has_key?(state.instances, instance) do
      {put_in(state, [:instances, instance], info), :ok, [{:monitor, :process, info.pid}]}
    else
      {state, {:error, :capacity}, []}
    end
  end

  defp execute({:activate_plugin, descriptor}, state, _) do
    plugins = Map.get(state, :plugins, %{})
    previous = plugins[descriptor.name]

    conflict =
      Enum.any?(plugins, fn {name, other} ->
        name != descriptor.name and Enum.any?(descriptor.sources, &(&1 in other.sources))
      end)

    conflict =
      conflict or
        (previous != nil and previous.version == descriptor.version and
           previous.hash != descriptor.hash)

    if conflict or (map_size(plugins) >= 32 and not Map.has_key?(plugins, descriptor.name)) do
      {state, {:error, :plugin_conflict}, []}
    else
      {Map.put(state, :plugins, Map.put(plugins, descriptor.name, descriptor)), :ok, []}
    end
  end

  defp execute({:deactivate_plugin, name}, state, _),
    do: {Map.put(state, :plugins, Map.delete(Map.get(state, :plugins, %{}), name)), :ok, []}

  defp execute({:key, key, owner, sender, fingerprint}, state, _) do
    case {state.names[key], state.keys[key]} do
      {%{owner: ^owner}, %{fingerprint: ^fingerprint, sender: previous}}
      when previous != sender ->
        {state, {:error, :key_reuse}, []}

      {%{owner: ^owner}, _} when map_size(state.keys) < state.limit ->
        {put_in(state, [:keys, key], %{fingerprint: fingerprint, sender: sender}), :ok, []}

      {%{owner: ^owner}, _} ->
        {state, {:error, :capacity}, []}

      _ ->
        {state, {:error, :not_owner}, []}
    end
  end

  defp execute({:down, pid, :noconnection}, state, _) do
    instances =
      Map.new(state.instances, fn {node, info} ->
        {node, if(info.pid == pid, do: %{info | status: :unreachable}, else: info)}
      end)

    {%{state | instances: instances}, :ok, [{:monitor, :node, node(pid)}]}
  end

  defp execute({:down, pid, _}, state, index) do
    names =
      Enum.reduce(state.names, %{}, fn {key, entry}, names ->
        cond do
          entry.owner == pid and Map.get(entry, :backup) != nil ->
            Map.put(names, key, %{owner: entry.backup, token: index})

          entry.owner == pid ->
            names

          Map.get(entry, :backup) == pid ->
            Map.put(names, key, Map.delete(entry, :backup))

          true ->
            Map.put(names, key, entry)
        end
      end)

    instances = Map.reject(state.instances, fn {_, info} -> info.pid == pid end)

    monitors =
      for {key, entry} <- names,
          state.names[key].owner == pid,
          do: {:monitor, :process, entry.owner}

    {%{state | names: names, instances: instances}, :ok, monitors}
  end

  defp execute({:nodeup, instance}, state, _) do
    effects = for pid <- owners(state), node(pid) == instance, do: {:monitor, :process, pid}
    {state, :ok, effects}
  end

  defp execute({:nodedown, _}, state, _), do: {state, :ok, []}
  defp execute(_, state, _), do: {state, {:error, :invalid_command}, []}

  @impl true
  def state_enter(:leader, state), do: Enum.map(owners(state), &{:monitor, :process, &1})
  def state_enter(_, _), do: []

  def query({:lookup, key}, state) do
    case state.names[key] do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  def query({:lookup_many, keys}, state),
    do: %{revision: Map.get(state, :revision, 0), entries: Map.take(state.names, keys)}

  def query(:instances, state), do: state.instances
  def query(:plugins, state), do: Map.get(state, :plugins, %{})

  def query(:summary, state),
    do: %{
      names: map_size(state.names),
      key_domains: map_size(state.keys),
      instances: state.instances
    }

  defp owners(state),
    do:
      Enum.uniq(
        (Enum.flat_map(state.names, fn {_, entry} -> [entry.owner, Map.get(entry, :backup)] end)
         |> Enum.filter(&is_pid/1)) ++
          Enum.map(state.instances, fn {_, info} -> info.pid end)
      )
end
