defmodule Lixi.Plugins.Call do
  @moduledoc "A supervised callback with an owner, a deadline and no unbounded task queue."
  use GenServer, restart: :temporary

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  def run(descriptor, function, arguments) do
    evaluate(fn ->
      hashes = Map.get(descriptor, :code_hashes, [{descriptor.module, descriptor.code_hash}])

      if Enum.all?(hashes, fn {module, hash} -> module.module_info(:md5) == hash end),
        do: apply(descriptor.module, function, arguments ++ [descriptor.config]),
        else: throw(:plugin_code_changed)
    end)
  end

  def evaluate(function, timeout \\ Application.get_env(:lixi, :plugin_timeout, 5_000))
      when is_function(function, 0) do
    case DynamicSupervisor.start_child(
           Lixi.PluginCallSupervisor,
           {__MODULE__, {self(), function, timeout}}
         ) do
      {:ok, pid} -> GenServer.call(pid, :await, 6_000)
      {:error, :max_children} -> {:error, :plugin_capacity}
      _ -> {:error, :plugin_unavailable}
    end
  catch
    :exit, _ -> {:error, :plugin_failed}
  end

  @impl true
  def init({owner, function, timeout}) do
    Process.flag(:trap_exit, true)

    task =
      Task.async(fn ->
        try do
          {:ok, function.()}
        rescue
          _ -> {:error, :plugin_exception}
        catch
          _, _ -> {:error, :plugin_exception}
        end
      end)

    timer =
      Process.send_after(self(), :timeout, timeout)

    {:ok, %{owner: Process.monitor(owner), task: task, timer: timer, from: nil, result: nil}}
  end

  @impl true
  def handle_call(:await, from, %{result: nil} = state), do: {:noreply, %{state | from: from}}
  def handle_call(:await, _, state), do: {:stop, :normal, state.result, state}
  @impl true
  def handle_info({ref, result}, %{task: %{ref: ref}} = state), do: finish(state, result)
  def handle_info(:timeout, state), do: finish(state, {:error, :plugin_timeout})
  def handle_info({:DOWN, ref, _, _, _}, %{owner: ref} = state), do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, _, _, _}, %{task: %{ref: ref}, result: nil} = state),
    do: finish(state, {:error, :plugin_failed})

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}
  def handle_info(_, state), do: {:noreply, state}

  defp finish(state, result) do
    if state.from do
      GenServer.reply(state.from, result)
      {:stop, :normal, state}
    else
      {:noreply, %{state | result: result}}
    end
  end

  @impl true
  def terminate(_, state) do
    Process.cancel_timer(state.timer)
    if Process.alive?(state.task.pid), do: Process.exit(state.task.pid, :kill)
  end
end
