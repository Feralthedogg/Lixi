defmodule Lixi.TestInbox do
  use GenServer
  def start, do: GenServer.start(__MODULE__, [])
  def init(events), do: {:ok, events}
  def handle_info({:lixi_event, event}, state), do: {:noreply, Enum.take([event | state], 256)}
  def handle_info(_, state), do: {:noreply, state}
  def handle_call(:events, _, state), do: {:reply, Enum.reverse(state), state}
end

defmodule Lixi.TestCluster do
  use GenServer, shutdown: 30_000
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, timeout: 30_000)
  def info(pid), do: GenServer.call(pid, :info)

  def init(_) do
    Process.flag(:trap_exit, true)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    :gen_tcp.close(listener)

    epmd =
      Port.open({:spawn_executable, System.find_executable("epmd")}, [
        :binary,
        :exit_status,
        args: [~c"-port", Integer.to_charlist(port), ~c"-address", ~c"127.0.0.1"]
      ])

    :ok = await_epmd(port, 100)
    paths = :code.get_path()

    args = [
      ~c"+S",
      ~c"2:2",
      ~c"-start_epmd",
      ~c"false",
      ~c"-setcookie",
      ~c"lixi_test_cluster",
      ~c"-kernel",
      ~c"connect_all",
      ~c"false",
      ~c"-pa" | paths
    ]

    peers =
      Enum.map([:lixi_test_a, :lixi_test_b, :lixi_test_c, :lixi_test_worker], fn name ->
        {:ok, controller, instance} =
          :peer.start_link(%{
            name: name,
            host: ~c"127.0.0.1",
            longnames: true,
            connection: :standard_io,
            args: args,
            env: [{~c"ERL_EPMD_PORT", Integer.to_charlist(port)}],
            wait_boot: 10_000
          })

        {controller, instance}
      end)

    nodes = Enum.map(peers, &elem(&1, 1))

    for {controller, instance} <- peers, other <- nodes, other != instance do
      true = :peer.call(controller, Node, :connect, [other])
    end

    directory = Path.expand("test/runtime/cluster-#{Base.encode16(:crypto.strong_rand_bytes(5))}")
    base = Application.get_all_env(:lixi)

    for {controller, instance} <- peers do
      :peer.call(controller, :application, :load, [:lixi])

      config =
        Keyword.merge(base,
          cluster_enabled: true,
          cluster_nodes: Enum.take(nodes, 3),
          cluster_timeout: 500,
          data_dir: Path.join(directory, Atom.to_string(instance)),
          start_server: true,
          port: 0,
          ip: {127, 0, 0, 1}
        )

      for {key, value} <- config,
          do: :peer.call(controller, Application, :put_env, [:lixi, key, value])

      :peer.call(controller, :logger, :set_primary_config, [:level, :error])
      :peer.call(controller, :application, :load, [:logger])
      :peer.call(controller, Application, :put_env, [:logger, :level, :error])
      {:ok, _} = :peer.call(controller, Application, :ensure_all_started, [:lixi], 15_000)
      :peer.call(controller, :logger, :set_primary_config, [:level, :error])
    end

    {:ok, %{peers: peers, epmd: epmd, epmd_port: port, directory: directory}}
  end

  defp await_epmd(_, 0), do: {:error, :epmd_not_started}

  defp await_epmd(port, attempts) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100) do
      {:ok, socket} ->
        :gen_tcp.send(socket, <<0, 1, 110>>)
        :gen_tcp.recv(socket, 4, 100)
        :gen_tcp.close(socket)
        :ok

      _ ->
        Process.sleep(10)
        await_epmd(port, attempts - 1)
    end
  end

  def handle_call(:info, _, state), do: {:reply, state, state}
  def handle_info(_, state), do: {:noreply, state}

  def terminate(_, state) do
    for {controller, _} <- state.peers do
      if Process.alive?(controller), do: :peer.stop(controller)
    end

    System.cmd(System.find_executable("epmd"), [
      "-port",
      Integer.to_string(state.epmd_port),
      "-kill"
    ])

    if Port.info(state.epmd), do: Port.close(state.epmd)
  end
end
