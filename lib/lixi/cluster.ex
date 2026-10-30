defmodule Lixi.Cluster do
  @moduledoc "Routes control requests to owners; media remains on its original node."
  alias Lixi.Cluster.Coordinator

  def lookup(key) do
    case entry(key) do
      {:ok, entry} -> {:ok, entry.owner}
      error -> error
    end
  end

  def entry(key) do
    case Coordinator.query({:lookup, key}) do
      {:ok, {:ok, entry}} -> {:ok, entry}
      {:ok, {:error, :not_found}} -> {:error, :not_found}
      _ -> {:error, :unavailable}
    end
  end

  def claim(key, owner \\ self()), do: Coordinator.command({:claim, key, owner})
  def release(key, owner \\ self()), do: Coordinator.command({:release, key, owner})
  def move(key, old, new), do: Coordinator.command({:move, key, old, new})

  def remember_key(key, owner, sender, fingerprint),
    do: Coordinator.command({:key, key, owner, sender, fingerprint})

  def instances do
    case Coordinator.query(:instances) do
      {:ok, instances} -> {:ok, instances}
      error -> error
    end
  end

  def candidates(key, purpose \\ :idle) do
    with {:ok, instances} <- instances() do
      nodes =
        instances
        |> Enum.filter(fn {instance, info} ->
          instance == node(info.pid) and info.status == :accepting and
            info.players < info.max_players and
            (purpose != :playback or worker_ratio(info) < 1)
        end)
        |> Enum.sort_by(fn {instance, info} ->
          {max(info.players / max(info.max_players, 1), worker_ratio(info)),
           -:erlang.phash2({key, instance})}
        end)
        |> Enum.map(&elem(&1, 0))

      if nodes == [], do: {:error, :draining}, else: {:ok, nodes}
    end
  end

  def call(server, message, timeout \\ 5_000) do
    GenServer.call(server, message, timeout)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def rpc(instance, module, function, arguments) when instance == node(),
    do: apply(module, function, arguments)

  def rpc(instance, module, function, arguments) do
    :erpc.call(instance, module, function, arguments, 5_000)
  catch
    :error, {:erpc, _} -> {:error, :unavailable}
    :exit, _ -> {:error, :unavailable}
  end

  def start_player(session, user, guild, owner, purpose \\ :idle) do
    case lookup({:player, session, guild}) do
      {:ok, pid} -> {:ok, pid}
      {:error, :not_found} -> allocate_player(session, user, guild, owner, purpose)
      error -> error
    end
  end

  defp allocate_player(session, user, guild, owner, purpose) do
    with {:ok, instances} <- candidates({session, guild}, purpose) do
      Enum.reduce_while(instances, {:error, :capacity}, fn instance, _ ->
        case rpc(instance, __MODULE__, :start_player_local, [session, user, guild, owner, purpose]) do
          {:ok, _} = result -> {:halt, result}
          error -> {:cont, error}
        end
      end)
    end
  end

  def start_player_local(session, user, guild, owner, purpose \\ :idle) do
    if Lixi.Lifecycle.accepting?() do
      permit = if purpose == :playback, do: Lixi.Admission.acquire(), else: {:ok, nil}

      with {:ok, lease} <- permit do
        result =
          DynamicSupervisor.start_child(
            Lixi.PlayerSupervisor,
            {Lixi.Player,
             session: session, user: user, guild: guild, owner: owner, worker_lease: lease}
          )

        case result do
          {:ok, _} ->
            if pid = Process.whereis(Lixi.Cluster.Member), do: send(pid, :heartbeat)
            result

          error ->
            Lixi.Admission.release(lease)

            if error == {:error, :already_owned},
              do: lookup({:player, session, guild}),
              else: error
        end
      end
    else
      {:error, :draining}
    end
  end

  defp worker_ratio(%{workers: workers}),
    do: workers.playback / max(workers.max_playback, 1)

  defp worker_ratio(_), do: 1.0

  def terminate_player(pid),
    do: rpc(node(pid), __MODULE__, :terminate_player_local, [pid])

  def terminate_player_local(pid) do
    case DynamicSupervisor.terminate_child(Lixi.PlayerSupervisor, pid) do
      {:error, :not_found} -> if Process.alive?(pid), do: {:error, :unavailable}, else: :ok
      result -> result
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def ready? do
    case instances() do
      {:ok, instances} ->
        Lixi.Lifecycle.accepting?() and Map.has_key?(instances, node()) and
          is_pid(Process.whereis(Lixi.Sessions)) and is_pid(Process.whereis(Lixi.Plugins.Manager))

      _ ->
        false
    end
  end

  def deliver_socket(socket, event) do
    if node(socket) == node() do
      case Process.info(socket, :message_queue_len) do
        {:message_queue_len, length} when length < 256 ->
          :erlang.send(socket, {:lixi_event, event}, [:nosuspend, :noconnect])

        _ ->
          {:error, :socket_unavailable}
      end
    else
      :erpc.call(node(socket), __MODULE__, :deliver_socket, [socket, event], 250)
    end
  catch
    :error, {:erpc, _} -> {:error, :socket_unavailable}
  end
end
