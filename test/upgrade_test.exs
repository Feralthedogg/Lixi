defmodule Lixi.UpgradeTest do
  use ExUnit.Case, async: false
  import Lixi.TestHelpers

  @tag timeout: 30_000
  test "a live player, worker, Voice and websocket survive atomic patch, rollback and failed activation" do
    original_directory = Application.fetch_env!(:lixi, :data_dir)
    directory = Path.expand("test/runtime/upgrade-#{Base.encode16(:crypto.strong_rand_bytes(5))}")
    Application.put_env(:lixi, :data_dir, directory)

    on_exit(fn ->
      Application.delete_env(:lixi, :upgrade_loader)
      Application.put_env(:lixi, :data_dir, original_directory)
      :persistent_term.erase({Lixi.Upgrade, :defaults})
      :persistent_term.erase({Lixi.Upgrade, :version})
      Supervisor.terminate_child(Lixi.Supervisor, Lixi.Upgrade)
      Supervisor.restart_child(Lixi.Supervisor, Lixi.Upgrade)
      Lixi.Lifecycle.resume()
    end)

    base = Lixi.Upgrade.version()
    target = base <> "-hot"
    bundle = build_bundle(directory, base, target)
    server = start_supervised!({Bandit, plug: Lixi.Router, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    headers = [
      {"Authorization", "youshallnotpass"},
      {"User-Id", "123"},
      {"Client-Name", "upgrade-test/1.0"}
    ]

    {:ok, socket} = Lixi.TestSocket.start("ws://127.0.0.1:#{port}/v4/websocket", self(), headers)
    on_exit(fn -> if Process.alive?(socket), do: Process.exit(socket, :kill) end)
    assert_receive {:websocket, ^socket, %{"op" => "ready", "sessionId" => id}}, 1000
    track = fixture(48_000, 6000) |> track()
    path = "/v4/sessions/#{id}/players/456"
    request(:patch, path, %{track: %{encoded: track["encoded"]}, voice: voice()})
    {:ok, player} = Lixi.Sessions.player(id, "456")
    eventually(fn -> Lixi.Player.snapshot(player)["state"]["position"] >= 60 end)
    before = :sys.get_state(player)

    assert {:ok, %{version: ^target}} = Lixi.Upgrade.apply_bundle(bundle)
    assert apply(Lixi.Player, :patch_marker, []) == "candidate"
    patched = :sys.get_state(player)
    assert patched.upgrade_test_marker == "added"
    assert patched.worker == before.worker
    assert patched.connection == before.connection
    assert patched.epoch == before.epoch
    assert Process.alive?(socket)
    assert :ok = Lixi.Upgrade.bootstrap()
    assert Lixi.Upgrade.version() == target

    eventually(fn ->
      Lixi.Player.snapshot(player)["state"]["position"] >= before.position + 80
    end)

    {:ok, created} = Lixi.Sessions.player(id, "789", true)
    assert :sys.get_state(created).upgrade_test_marker == "added"

    assert {:ok, %{version: ^base}} = Lixi.Upgrade.rollback()
    refute function_exported?(Lixi.Player, :patch_marker, 0)
    assert :sys.get_state(player).worker == before.worker
    second = Path.join(directory, "failing")
    File.mkdir_p!(second)

    File.cp!(
      Path.join(bundle, "Elixir.Lixi.Player.beam"),
      Path.join(second, "Elixir.Lixi.Player.beam")
    )

    manifest = File.read!(Path.join(bundle, "manifest.json")) |> Jason.decode!()

    manifest =
      Map.put(manifest, "stateDefaults", %{
        "Lixi.Player" => %{"upgrade_test_failure_marker" => "must-rollback"}
      })

    File.write!(Path.join(second, "manifest.json"), Jason.encode!(manifest))
    Application.put_env(:lixi, :upgrade_loader, Lixi.TestFailingLoader)
    assert {:error, :code_load_failed} = Lixi.Upgrade.apply_bundle(second)
    Application.delete_env(:lixi, :upgrade_loader)
    refute Map.has_key?(:sys.get_state(player), :upgrade_test_failure_marker)
    refute function_exported?(Lixi.Player, :patch_marker, 0)
    assert :sys.get_state(player).connection == before.connection
    assert Process.alive?(socket)
    refute File.read!(Path.join(directory, "hot-upgrade.json")) =~ "test-token"

    pending = Path.join(directory, "hot-upgrade.json.pending")
    File.mkdir!(pending)
    assert {:error, :recovery_required} = Lixi.Upgrade.apply_bundle(second)
    assert Lixi.Upgrade.status().recovery_required
    assert Lixi.Lifecycle.mode() == :draining
    assert {:error, :recovery_required} = Lixi.Lifecycle.resume()
    assert :sys.get_state(player).connection == before.connection
    File.rmdir!(pending)
    assert :ok = Lixi.Upgrade.recover()
    refute Lixi.Upgrade.status().recovery_required
    refute Map.has_key?(:sys.get_state(player), :upgrade_test_failure_marker)

    paths = Path.wildcard("_build/test/lib/*/ebin") |> Enum.flat_map(&["-pa", Path.expand(&1)])

    script =
      "Application.load(:lixi); Application.put_env(:lixi, :data_dir, hd(System.argv())); :ok = Lixi.Upgrade.bootstrap(); :ok = Lixi.Upgrade.bootstrap(); IO.puts(\"BOOT_PATCH_OK\")"

    assert {output, 0} =
             System.cmd("elixir", ["--erl", "+S 2:2"] ++ paths ++ ["-e", script, directory],
               stderr_to_stdout: true
             )

    assert output =~ "BOOT_PATCH_OK"
    request(:delete, path)
    Lixi.Sessions.destroy(id, "789")
  end

  test "an interrupted defaults-only patch cannot commit before activation is ready" do
    previous_directory = Application.fetch_env!(:lixi, :data_dir)

    directory =
      Path.expand("test/runtime/recovery-#{Base.encode16(:crypto.strong_rand_bytes(5))}")

    Application.put_env(:lixi, :data_dir, directory)
    base = Lixi.Upgrade.version()
    file = :code.which(Lixi.Player)
    bytes = File.read!(file)

    recovery = %{
      ref: make_ref(),
      phase: :prepared,
      old_defaults: %{},
      old_journal: %{"schema" => 1, "patches" => [], "rollback" => nil},
      modules: [{Lixi.Player, file, bytes}],
      defaults: %{},
      target: "must-not-commit",
      mode: :accepting
    }

    :persistent_term.put({Lixi.Upgrade, :recovery}, recovery)
    Supervisor.terminate_child(Lixi.Supervisor, Lixi.Upgrade)
    assert {:ok, _} = Supervisor.restart_child(Lixi.Supervisor, Lixi.Upgrade)
    assert Lixi.Upgrade.version() == base
    refute Lixi.Upgrade.status().recovery_required

    on_exit(fn ->
      Application.put_env(:lixi, :data_dir, previous_directory)
      Supervisor.terminate_child(Lixi.Supervisor, Lixi.Upgrade)
      Supervisor.restart_child(Lixi.Supervisor, Lixi.Upgrade)
    end)
  end

  defp build_bundle(directory, base, target) do
    input = Path.join(directory, "input")
    File.mkdir_p!(input)
    source = File.read!("lib/lixi/player.ex")

    source =
      Regex.replace(
        ~r/end\s*$/,
        source,
        "def patch_marker, do: \"candidate\"\ndef upgrade_fields(state), do: {state.upgrade_test_marker, state.upgrade_test_failure_marker}\nend\n"
      )

    filename = Path.join(input, "player.ex")
    File.write!(filename, source)

    script =
      "[source, destination] = System.argv(); Kernel.ParallelCompiler.compile_to_path([source], destination)"

    {_, 0} =
      System.cmd(
        "elixir",
        [
          "--erl",
          "+S 2:2",
          "-pa",
          Path.expand("_build/test/lib/lixi/ebin"),
          "-e",
          script,
          filename,
          input
        ],
        stderr_to_stdout: true
      )

    File.rm!(filename)
    bytes = File.read!(Path.join(input, "Elixir.Lixi.Player.beam"))

    manifest = %{
      schema: 1,
      from: base,
      to: target,
      modules: [
        %{
          module: "Lixi.Player",
          sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
        }
      ],
      stateDefaults: %{"Lixi.Player" => %{"upgrade_test_marker" => "added"}}
    }

    File.write!(Path.join(input, "manifest.json"), Jason.encode!(manifest))
    input
  end
end
