defmodule Lixi.AdmissionTest do
  use ExUnit.Case, async: false
  import Lixi.TestHelpers

  setup context do
    if context[:supervisor_crash] do
      # Independent crash cases must not share OTP's restart-intensity budget.
      :ok = Application.stop(:lixi)
      {:ok, _} = Application.ensure_all_started(:lixi)

      on_exit(fn ->
        Application.stop(:lixi)
        {:ok, _} = Application.ensure_all_started(:lixi)
      end)
    end

    before = Application.fetch_env!(:lixi, :max_workers)
    probes = Application.fetch_env!(:lixi, :max_probe_workers)
    Application.put_env(:lixi, :max_workers, 1)
    Application.put_env(:lixi, :max_probe_workers, 1)

    on_exit(fn ->
      Application.put_env(:lixi, :max_workers, before)
      Application.put_env(:lixi, :max_probe_workers, probes)
    end)

    :ok
  end

  test "metadata probes succeed with a full playback pool and release their own slot" do
    file = fixture()
    {:ok, worker} = Lixi.Audio.Worker.start(self(), file, 1)
    on_exit(fn -> Lixi.Audio.Worker.stop(worker) end)
    assert_receive {:audio, ^worker, 1, {:ready, _}}, 2000
    assert {:error, :worker_capacity} = Lixi.Audio.Worker.start(self(), file, 2)
    assert {:ok, _} = Lixi.Sources.resolve(file)
    assert %{playback: 1, probes: 0, active: 1} = Lixi.Admission.snapshot()
    assert length(Lixi.Admission.snapshot().os_pids) == 1
    Lixi.Audio.Worker.stop(worker)
    assert Lixi.Admission.active() == 0
    assert {:ok, replacement} = Lixi.Audio.Worker.start(self(), file, 3)
    Lixi.Audio.Worker.stop(replacement)
  end

  test "parallel reservations cannot exceed either pool and owner death frees capacity" do
    parent = self()

    owners =
      for _ <- 1..16 do
        spawn(fn ->
          result = Lixi.Admission.acquire()
          send(parent, {:permit, self(), result})
          receive do: (:stop -> :ok)
        end)
      end

    results =
      for _ <- owners do
        assert_receive {:permit, pid, result}, 1000
        {pid, result}
      end

    assert Enum.count(results, &match?({_, {:ok, _}}, &1)) == 1
    assert {:ok, probe} = Lixi.Admission.acquire(:probe)
    assert {:error, :worker_capacity} = Lixi.Admission.acquire(:probe)
    assert %{playback: 1, probes: 1} = Lixi.Admission.snapshot()
    for pid <- owners, do: send(pid, :stop)
    Lixi.Admission.release(probe)
    eventually(fn -> Lixi.Admission.active() == 0 end)
  end

  @tag supervisor_crash: true
  test "released preparer leases remain charged until their physical worker exits, including restart" do
    old = Application.get_env(:lixi, :max_preparers)
    Application.put_env(:lixi, :max_preparers, 1)
    on_exit(fn -> Application.put_env(:lixi, :max_preparers, old) end)
    assert {:ok, playback, prepare} = Lixi.Admission.reserve_swapping(nil)
    parent = self()

    worker =
      spawn(fn ->
        :ok = Lixi.Admission.attach(prepare, nil)
        send(parent, :prepare_bound)
        receive do: (:stop -> :ok)
      end)

    on_exit(fn -> send(worker, :stop) end)
    assert_receive :prepare_bound
    Lixi.Admission.release(prepare)
    assert Lixi.Admission.snapshot().preparers == 1
    assert {:error, :worker_capacity} = Lixi.Admission.acquire(:prepare)
    admission = Process.whereis(Lixi.Admission)
    Process.exit(admission, :kill)

    eventually(fn ->
      is_pid(Process.whereis(Lixi.Admission)) and Process.whereis(Lixi.Admission) != admission
    end)

    assert Lixi.Admission.snapshot().preparers == 1
    assert {:error, :expired} = Lixi.Admission.transfer(prepare, self())
    assert {:error, :worker_capacity} = Lixi.Admission.acquire(:prepare)
    send(worker, :stop)
    eventually(fn -> Lixi.Admission.snapshot().preparers == 0 end)
    Lixi.Admission.release(playback)
  end

  test "pair admission cannot partially consume playback when preparation is full" do
    old = Application.get_env(:lixi, :max_preparers)
    Application.put_env(:lixi, :max_preparers, 1)
    on_exit(fn -> Application.put_env(:lixi, :max_preparers, old) end)
    {:ok, prepare} = Lixi.Admission.acquire(:prepare)
    assert {:error, :worker_capacity} = Lixi.Admission.reserve_swapping(nil)
    assert Lixi.Admission.snapshot().playback == 0
    assert {:ok, playback} = Lixi.Admission.acquire()
    assert {:ok, probe} = Lixi.Admission.acquire(:probe)
    for lease <- [prepare, playback, probe], do: Lixi.Admission.release(lease)
  end

  test "initializing workers retain capacity when the requesting owner dies" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, lease} = Lixi.Admission.acquire()
        send(parent, {:initializing_lease, lease})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:initializing_lease, lease}, 1000

    worker =
      spawn(fn ->
        :ok = Lixi.Admission.attach(lease, nil)
        send(parent, :initializer_attached)
        receive do: (:stop -> :ok)
      end)

    assert_receive :initializer_attached, 1000
    send(owner, :stop)
    eventually(fn -> not Process.alive?(owner) end)
    assert {:error, :worker_capacity} = Lixi.Admission.acquire()
    assert Lixi.Admission.snapshot().os_pids == []
    send(worker, :stop)
    eventually(fn -> Lixi.Admission.active() == 0 end)
  end

  test "new playback reserves capacity before player creation; unused reservations expire" do
    session = session()

    assert {:ok, player} =
             Lixi.Cluster.start_player_local(session, "123", "reserve", self(), :playback)

    on_exit(fn -> Lixi.Cluster.terminate_player(player) end)
    assert Lixi.Admission.snapshot().playback == 1

    assert {:error, :worker_capacity} =
             Lixi.Cluster.start_player_local(session, "123", "overflow", self(), :playback)

    send(player, :expire_reservation)
    eventually(fn -> Lixi.Admission.active() == 0 end)
    assert {:ok, idle} = Lixi.Cluster.start_player_local(session, "123", "idle", self())
    Lixi.Cluster.terminate_player(idle)
  end

  test "a killed Player keeps its physical worker slot until that worker stops" do
    file = fixture(48_000, 2000)
    id = session()
    {:ok, player} = Lixi.Sessions.player(id, "killed-owner", :playback)
    {:ok, patch} = Lixi.Player.validate(%{"track" => %{"identifier" => file}})
    {:ok, _} = Lixi.Player.update(player, patch, false)
    worker = :sys.get_state(player).worker
    :ok = :sys.suspend(worker)
    Process.exit(player, :kill)
    eventually(fn -> not Process.alive?(player) end)
    assert Lixi.Admission.snapshot().playback == 1
    assert {:error, :worker_capacity} = Lixi.Admission.acquire()
    :ok = :sys.resume(worker)
    eventually(fn -> Lixi.Admission.active() == 0 end)
  end

  @tag supervisor_crash: true
  test "seek can replace a worker while the playback pool is full" do
    file = fixture(48_000, 2000)
    track = track(file)
    id = session()
    {:ok, player} = Lixi.Sessions.player(id, "seek-capacity", :playback)
    on_exit(fn -> Lixi.Sessions.destroy(id, "seek-capacity") end)

    {:ok, patch} =
      Lixi.Player.validate(%{"track" => %{"encoded" => track["encoded"]}, "voice" => voice()})

    assert {:ok, _} = Lixi.Player.update(player, patch, false)
    eventually(fn -> :sys.get_state(player).position > 0 end)
    lease = :sys.get_state(player).worker_lease
    {:ok, seek} = Lixi.Player.validate(%{"position" => 600})
    assert {:ok, _} = Lixi.Player.update(player, seek, false)
    eventually(fn -> :sys.get_state(player).position > 600 end)
    assert :sys.get_state(player).track != nil
    assert :sys.get_state(player).worker_lease == lease
    admission = Process.whereis(Lixi.Admission)
    worker = :sys.get_state(player).worker
    Process.exit(admission, :kill)

    eventually(fn ->
      Process.whereis(Lixi.Admission) != nil and Process.whereis(Lixi.Admission) != admission
    end)

    assert Lixi.Admission.snapshot().playback == 1
    assert length(Lixi.Admission.snapshot().os_pids) == 1
    assert {:error, :worker_capacity} = Lixi.Admission.acquire()
    assert :sys.get_state(player).worker == worker
    Process.exit(worker, :kill)

    eventually(fn ->
      :sys.get_state(player).worker != worker and is_pid(:sys.get_state(player).worker)
    end)

    assert :sys.get_state(player).worker_lease == lease
    assert Lixi.Admission.snapshot().playback == 1
  end
end
