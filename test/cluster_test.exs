defmodule Lixi.ClusterTest do
  use ExUnit.Case, async: false
  import Lixi.TestHelpers
  alias Lixi.Cluster.Machine

  test "uncertain owner loss preserves ownership and confirmed death releases it" do
    state = Machine.init(%{})
    owner = self()
    key = {:voice, "123", "456"}
    {state, {:ok, _}, _} = Machine.apply(%{index: 1}, {:claim, key, owner}, state)
    {state, :ok, _} = Machine.apply(%{index: 2}, {:down, owner, :noconnection}, state)

    other =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {state, {:error, :owned}, _} = Machine.apply(%{index: 3}, {:claim, key, other}, state)
    {state, :ok, _} = Machine.apply(%{index: 4}, {:down, owner, :normal}, state)
    {_, {:ok, _}, _} = Machine.apply(%{index: 5}, {:claim, key, other}, state)
    send(other, :stop)
  end

  test "handoff finalization is idempotent and an aborted generation cannot arrive late" do
    owner = self()
    target = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(target, :stop) end)
    key = {:session, "generation-test"}
    ref = make_ref()
    state = Machine.init(%{})
    {state, {:ok, _}, _} = Machine.apply(%{index: 1}, {:claim, key, owner}, state)
    {state, :ok, _} = Machine.apply(%{index: 2}, {:abort_move, key, owner, target, 1, ref}, state)

    {state, {:error, :owner_changed}, _} =
      Machine.apply(%{index: 3}, {:begin_move, key, owner, target, 1, ref}, state)

    {state, {:ok, _}, _} =
      Machine.apply(%{index: 4}, {:begin_move, key, owner, target, 2, ref}, state)

    {state, :ok, _} = Machine.apply(%{index: 5}, {:finish_move, key, target, ref}, state)
    {state, :ok, _} = Machine.apply(%{index: 6}, {:finish_move, key, target, ref}, state)
    {state, :ok, _} = Machine.apply(%{index: 7}, {:down, target, :normal}, state)
    assert {:error, :not_found} = Machine.query({:lookup, key}, state)
  end

  test "a local directory restart preserves claims of surviving processes" do
    key = {:test_claim, make_ref()}
    assert {:ok, entry} = Lixi.Cluster.claim(key)
    previous = Process.whereis(Lixi.Cluster.Coordinator)
    Process.exit(previous, :kill)

    eventually(fn ->
      pid = Process.whereis(Lixi.Cluster.Coordinator)
      is_pid(pid) and pid != previous
    end)

    assert {:ok, ^entry} = Lixi.Cluster.entry(key)
    assert :ok = Lixi.Cluster.release(key)
    send(Lixi.Cluster.Member, :heartbeat)
  end

  @tag timeout: 90_000
  @tag distributed: true
  test "a three-voter quorum and a worker preserve media through session transfer and a partition" do
    harness = start_supervised!(Lixi.TestCluster)
    %{peers: peers} = Lixi.TestCluster.info(harness)
    [{a, an}, {b, bn}, {c, cn}, {d, dn}] = peers

    assert await_ready(peers, System.monotonic_time(:millisecond) + 10_000)

    port = http_port(a)

    headers = [
      {"Authorization", "youshallnotpass"},
      {"User-Id", "123"},
      {"Client-Name", "cluster-test/1.0"}
    ]

    {:ok, socket} = Lixi.TestSocket.start("ws://127.0.0.1:#{port}/v4/websocket", self(), headers)
    on_exit(fn -> if Process.alive?(socket), do: Process.exit(socket, :kill) end)
    assert_receive {:websocket, ^socket, %{"op" => "ready", "sessionId" => id}}, 1000
    assert {:ok, "123"} = :peer.call(c, Lixi.Sessions, :user, [id])
    :peer.call(b, Lixi.Sessions, :settings, [id, %{"resuming" => true, "timeout" => 60}])

    for {peer, instance} <- peers,
        instance != cn,
        do: :peer.call(peer, Lixi.Lifecycle, :drain, [])

    {:ok, player} = :peer.call(b, Lixi.Sessions, :player, [id, "456", true])
    assert node(player) == cn

    for {peer, instance} <- peers,
        instance != cn,
        do: :peer.call(peer, Lixi.Lifecycle, :resume, [])

    track = fixture(48_000, 12_000) |> track()

    {:ok, patch} =
      Lixi.Player.validate(%{"track" => %{"encoded" => track["encoded"]}, "voice" => voice()})

    assert {:ok, _} = :peer.call(a, Lixi.Player, :update, [player, patch, false])

    eventually(fn ->
      :peer.call(c, Lixi.Player, :snapshot, [player])["state"]["position"] >= 60
    end)

    before = :peer.call(c, :sys, :get_state, [player])
    {:ok, original_owner} = :peer.call(a, Lixi.Cluster, :lookup, [{:session, id}])
    target = if node(original_owner) == dn, do: bn, else: dn
    assert :ok = :peer.call(a, Lixi.Sessions, :move, [id, target])
    {:ok, moved_owner} = :peer.call(b, Lixi.Cluster, :lookup, [{:session, id}])
    assert node(moved_owner) == target
    eventually(fn -> :peer.call(c, :sys, :get_state, [player]).owner == moved_owner end)
    after_move = :peer.call(c, :sys, :get_state, [player])
    assert after_move.worker == before.worker
    assert after_move.connection == before.connection
    assert after_move.epoch == before.epoch
    assert Process.alive?(socket)
    assert {:ok, ^player} = :peer.call(d, Lixi.Sessions, :player, [id, "456"])

    for destination <- [node(original_owner), target] do
      assert :ok = :peer.call(a, Lixi.Sessions, :move, [id, destination])

      for {peer, instance} <- peers do
        manager = :peer.call(peer, Process, :whereis, [Lixi.Sessions])
        {:monitors, monitors} = :peer.call(peer, Process, :info, [manager, :monitors])

        assert Enum.count(monitors, &(&1 == {:process, player})) ==
                 if(instance == destination, do: 1, else: 0)
      end
    end

    Process.exit(socket, :kill)

    eventually(fn ->
      :peer.call(b, :sys, :get_state, [moved_owner]).sessions[id].socket == nil
    end)

    resume_url = "ws://127.0.0.1:#{http_port(b)}/v4/websocket"
    {:ok, resumed} = Lixi.TestSocket.start(resume_url, self(), [{"Session-Id", id} | headers])
    on_exit(fn -> if Process.alive?(resumed), do: Process.exit(resumed, :kill) end)

    assert_receive {:websocket, ^resumed,
                    %{"op" => "ready", "resumed" => true, "sessionId" => ^id}},
                   1_000

    after_resume = :peer.call(c, :sys, :get_state, [player])
    assert after_resume.worker == before.worker
    assert after_resume.connection == before.connection

    for peer <- [c, d],
        do: assert({:ok, _} = :peer.call(peer, Lixi.Plugins, :install, [Lixi.TestPlugin.V2]))

    assert :ok = :peer.call(d, Lixi.Plugins, :activate, ["fixture", "2.0.0"])
    :peer.call(c, Lixi.Lifecycle, :drain, [])
    assert :peer.call(c, Lixi.Cluster, :ready?, []) == false
    url = String.to_charlist("http://127.0.0.1:#{http_port(c)}/v4/sessions/#{id}/players")

    assert {:ok, {{_, 200, _}, _, _}} =
             :httpc.request(:get, {url, [{~c"authorization", ~c"youshallnotpass"}]}, [], [])

    {:ok, sender} = :peer.call(c, Lixi.TestInbox, :start, [])
    {:ok, contender} = :peer.call(b, Lixi.TestInbox, :start, [])
    key = {:voice, "partition-test", id}
    fingerprint = :crypto.hash(:sha256, "test-transport-key")
    assert {:ok, _} = :peer.call(a, Lixi.Cluster, :claim, [key, sender])
    assert :ok = :peer.call(a, Lixi.Cluster, :remember_key, [key, sender, sender, fingerprint])
    frames_before = :peer.call(c, :sys, :get_state, [before.connection]).frames

    for {peer, _} <- peers,
        do: :peer.call(peer, Application, :put_env, [:kernel, :dist_auto_connect, :never])

    for other_node <- [an, bn, dn], do: :peer.call(c, Node, :disconnect, [other_node])
    assert {:error, :unavailable} = :peer.call(c, Lixi.Cluster, :claim, [{:isolated, id}])

    eventually(
      fn -> :peer.call(a, Lixi.Cluster, :claim, [key, contender]) == {:error, :owned} end,
      30
    )

    assert :peer.call(c, Process, :alive?, [sender])
    assert :peer.call(c, :sys, :get_state, [before.connection]).frames > frames_before + 10

    assert {:error, :unavailable} = :peer.call(a, Lixi.Sessions, :destroy, [id, "456"])
    assert {:ok, ^player} = :peer.call(a, Lixi.Sessions, :player, [id, "456"])
    assert {:error, :unavailable} = :peer.call(a, Lixi.Player, :fetch_snapshot, [player])

    assert {:ok, {:ok, 200, %{version: "2.0.0"}}} =
             :peer.call(b, Lixi.Plugins, :request, [
               "fixture",
               %{method: "GET", path: ["version"]}
             ])

    for {peer, instance} <- peers,
        {_, other_node} <- peers,
        other_node != instance,
        do: :peer.call(peer, Node, :connect, [other_node])

    eventually(fn -> :peer.call(a, Lixi.Cluster, :lookup, [key]) == {:ok, sender} end, 30)
    :peer.call(c, Process, :exit, [sender, :kill])

    eventually(
      fn -> match?({:ok, _}, :peer.call(a, Lixi.Cluster, :claim, [key, contender])) end,
      100
    )

    assert {:error, :key_reuse} =
             :peer.call(a, Lixi.Cluster, :remember_key, [key, contender, contender, fingerprint])

    assert :ok = :peer.call(a, Lixi.Sessions, :destroy, [id, "456"])
  end

  defp await_ready(peers, deadline) do
    ready = Enum.all?(peers, fn {peer, _} -> :peer.call(peer, Lixi.Cluster, :ready?, []) end)

    cond do
      ready ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        for {peer, name} <- peers,
            do:
              IO.inspect({name, :peer.call(peer, Lixi.Cluster.Coordinator, :query, [:instances])},
                label: "cluster readiness"
              )

        false

      true ->
        Process.sleep(50)
        await_ready(peers, deadline)
    end
  end

  defp http_port(peer) do
    {_, server, _, _} =
      Enum.find(:peer.call(peer, Supervisor, :which_children, [Lixi.Supervisor]), fn {id, _, _, _} ->
        match?({Bandit, _}, id)
      end)

    {:ok, {_, port}} = :peer.call(peer, ThousandIsland, :listener_info, [server])
    port
  end
end
