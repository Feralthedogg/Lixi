defmodule Lixi.PluginPackageTest do
  use ExUnit.Case, async: false
  import Lixi.TestHelpers
  import Plug.Conn
  alias Lixi.Plugins.Package

  setup_all do
    root = Path.expand("test/runtime/plugins-#{Base.encode16(:crypto.strong_rand_bytes(5))}")
    staging = Path.join(root, "staging")
    source = Path.join(root, "source")
    File.mkdir_p!(source)

    on_exit(fn ->
      for name <- ["source", "staging", "generated"], do: cleanup_input(Path.join(root, name))
    end)

    for version <- [1, 2, 3] do
      project = Path.join(source, "v#{version}")
      File.mkdir_p!(Path.join(project, "lib"))

      manifest = %{
        schema: 1,
        apiVersion: 1,
        name: if(version == 3, do: "conflicting_fixture", else: "packaged_fixture"),
        version: "#{version}.0.0",
        entry: "PackagedFixture.V#{version}"
      }

      File.write!(Path.join(project, "plugin.json"), Jason.encode!(manifest))
      source = fixture_source(version)

      source =
        if version == 3,
          do:
            String.replace(source, "name: \"packaged_fixture\"", "name: \"conflicting_fixture\""),
          else: source

      File.write!(Path.join(project, "lib/plugin.ex"), source)

      Mix.Tasks.Lixi.Plugin.Pack.run([
        project,
        "--output",
        Path.join(staging, "fixture-#{version}")
      ])
    end

    on_load = Path.join(source, "on-load")
    File.mkdir_p!(Path.join(on_load, "lib"))

    File.write!(
      Path.join(on_load, "plugin.json"),
      Jason.encode!(%{
        schema: 1,
        apiVersion: 1,
        name: "onload_fixture",
        version: "1.0.0",
        entry: "PackagedFixture.OnLoad"
      })
    )

    File.write!(Path.join(on_load, "lib/plugin.ex"), """
    defmodule PackagedFixture.OnLoad do
      @behaviour Lixi.Plugin
      @on_load :init
      def init, do: :ok
      def metadata, do: %{name: "onload_fixture", version: "1.0.0", sources: []}
      def request(_, _), do: {:ok, 200, %{ok: true}}
    end
    """)

    Mix.Tasks.Lixi.Plugin.Pack.run([on_load, "--output", Path.join(staging, "on-load")])
    {:ok, %{root: root, staging: staging}}
  end

  setup context do
    previous =
      for key <- [:data_dir, :plugin_root, :admin_token],
          into: %{},
          do: {key, Application.get_env(:lixi, key)}

    Application.put_env(:lixi, :data_dir, context.root)
    Application.put_env(:lixi, :plugin_root, context.staging)
    Application.put_env(:lixi, :admin_token, "package-test-admin-token-012345")
    Process.register(self(), Lixi.PackageProbe)

    on_exit(fn ->
      pending = Path.join(context.root, "plugins/installed.json.pending")
      if match?({:ok, %{type: :directory}}, File.lstat(pending)), do: File.rmdir(pending)

      for name <- ["packaged_fixture", "onload_fixture", "conflicting_fixture"] do
        Lixi.Plugins.deactivate(name)

        for version <- ["0.9.0", "1.0.0", "2.0.0", "3.0.0"],
            do: Lixi.Plugins.remove(name, version)
      end

      for {key, value} <- previous do
        if value == nil,
          do: Application.delete_env(:lixi, key),
          else: Application.put_env(:lixi, key, value)
      end
    end)

    :ok
  end

  test "a staged package installs through the authenticated API and serves source and HTTP callbacks",
       ctx do
    file = fixture()
    body = %{bundle: "fixture-1", config: %{uri: file, secret: "package-config-private"}}
    assert request(:post, "/v4/lixi/plugins/packages", body).status == 403
    response = admin(:post, "/v4/lixi/plugins/packages", body)
    assert response.status == 201
    assert byte_size(json(response)["package"]) == 64

    assert admin(:post, "/v4/lixi/plugins/packaged_fixture/activate", %{version: "1.0.0"}).status ==
             200

    result = json(request(:get, "/v4/loadtracks?identifier=packaged_fixture:demo"))
    assert result["loadType"] == "track"
    assert result["data"]["info"]["identifier"] == file
    assert json(request(:get, "/v4/plugins/packaged_fixture/health"))["label"] == "v1"
    refute admin(:get, "/v4/lixi/plugins").resp_body =~ "package-config-private"
    assert {:ok, %{mode: mode}} = File.stat(Path.join(ctx.root, "plugins/installed.json"))
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "a leased old package keeps executing while the new version is activated" do
    assert {:ok, _} = Lixi.Plugins.install_package("fixture-1")
    assert :ok = Lixi.Plugins.activate("packaged_fixture", "1.0.0")

    task =
      Task.async(fn ->
        Lixi.Plugins.request("packaged_fixture", %{method: "GET", path: ["wait"]})
      end)

    assert_receive {:package_waiting, callback}, 1_000
    assert {:ok, _} = Lixi.Plugins.install_package("fixture-2")
    assert :ok = Lixi.Plugins.activate("packaged_fixture", "2.0.0")
    assert {:error, :plugin_in_use} = Lixi.Plugins.remove("packaged_fixture", "1.0.0")

    assert {:ok, {:ok, 200, %{label: "v2"}}} =
             Lixi.Plugins.request("packaged_fixture", %{method: "GET", path: ["health"]})

    send(callback, :continue)
    assert {:ok, {:ok, 200, %{label: "v1"}}} = Task.await(task)
    eventually(fn -> Lixi.Plugins.remove("packaged_fixture", "1.0.0") == :ok end)
  end

  test "bad hashes, toolchains, symlinks and module reuse do not change an active package", ctx do
    assert {:ok, original} = Lixi.Plugins.install_package("fixture-1")
    assert :ok = Lixi.Plugins.activate("packaged_fixture", "1.0.0")
    assert {:error, :invalid_bundle_id} = Lixi.Plugins.install_package("../outside")

    for {id, change, expected} <- [
          {"bad-api", &Map.put(&1, "apiVersion", 999), :invalid_plugin_manifest},
          {"bad-toolchain", &Map.put(&1, "otp", "0"), :plugin_toolchain_mismatch},
          {"reuse-module", &Map.put(&1, "version", "1.1.0"), :plugin_module_conflict}
        ] do
      copy_package(ctx.staging, id, change)
      assert {:error, ^expected} = Lixi.Plugins.install_package(id)
    end

    copy_package(ctx.staging, "bad-hash", & &1)

    File.write!(
      Path.join(ctx.staging, "bad-hash/Elixir.PackagedFixture.V1.Helper.beam"),
      "invalid-beam"
    )

    assert {:error, :invalid_plugin_beam} = Lixi.Plugins.install_package("bad-hash")
    File.ln_s!(Path.join(ctx.staging, "fixture-1"), Path.join(ctx.staging, "symlink"))
    assert {:error, :invalid_plugin_directory} = Lixi.Plugins.install_package("symlink")
    assert {:ok, ^original} = Lixi.Plugins.install_package("fixture-1")

    assert {:ok, {:ok, 200, %{label: "v1"}}} =
             Lixi.Plugins.request("packaged_fixture", %{method: "GET", path: ["health"]})
  end

  test "an on_load package cannot run its initializer in the server VM" do
    assert {:error, :plugin_code_load_failed} = Lixi.Plugins.install_package("on-load")
    assert :code.is_loaded(PackagedFixture.OnLoad) == false
  end

  test "a registry write failure preserves installed and active versions", ctx do
    assert {:ok, _} = Lixi.Plugins.install_package("fixture-1")
    assert :ok = Lixi.Plugins.activate("packaged_fixture", "1.0.0")
    path = Path.join(ctx.root, "plugins/installed.json.pending")
    File.mkdir!(path)
    assert {:error, :plugin_registry_write_failed} = Lixi.Plugins.install_package("fixture-2")

    refute Enum.any?(
             Lixi.Plugins.Manager.catalogue(),
             &(&1.name == "packaged_fixture" and &1.version == "2.0.0")
           )

    assert {:error, :plugin_registry_write_failed} = Lixi.Plugins.deactivate("packaged_fixture")

    assert {:ok, {:ok, 200, %{label: "v1"}}} =
             Lixi.Plugins.request("packaged_fixture", %{method: "GET", path: ["health"]})

    File.rmdir!(path)
    assert {:ok, _} = Lixi.Plugins.install_package("fixture-2")
    assert :ok = Lixi.Plugins.activate("packaged_fixture", "2.0.0")
  end

  test "installed code, configuration and standalone activation survive a clean VM boot", ctx do
    assert {:ok, _} =
             Lixi.Plugins.install_package("fixture-2", %{
               "secret" => "persisted-config",
               "marker" => "restored-config"
             })

    assert :ok = Lixi.Plugins.activate("packaged_fixture", "2.0.0")
    assert boot(ctx.root, "2.0.0", "restored-config") =~ "PACKAGE_BOOT_OK"
    assert :ok = Lixi.Plugins.deactivate("packaged_fixture")
    assert boot(ctx.root, "disabled") =~ "PACKAGE_BOOT_OK"
    assert :ok = Lixi.Plugins.remove("packaged_fixture", "2.0.0")
    {:ok, registry} = Package.read_registry()
    assert registry.installed == []
  end

  test "a conflicting activation never changes the registry even while writes are unavailable",
       ctx do
    assert {:ok, _} = Lixi.Plugins.install_package("fixture-2")
    assert :ok = Lixi.Plugins.activate("packaged_fixture", "2.0.0")
    assert {:ok, _} = Lixi.Plugins.install_package("fixture-3")
    registry = Path.join(ctx.root, "plugins/installed.json")
    before = File.read!(registry)
    pending = registry <> ".pending"
    File.mkdir!(pending)
    assert {:error, :plugin_conflict} = Lixi.Plugins.activate("conflicting_fixture", "3.0.0")
    assert File.read!(registry) == before
    refute Lixi.Plugins.Manager.status().recovery_required
    File.rmdir!(pending)
    assert boot(ctx.root, "2.0.0") =~ "PACKAGE_BOOT_OK"
  end

  test "committed registry changes override a stale restart snapshot without losing live leases" do
    before_install = :persistent_term.get({Lixi.Plugins.Manager, :catalogue})
    assert {:ok, _} = Lixi.Plugins.install_package("fixture-2")
    assert :ok = Lixi.Plugins.activate("packaged_fixture", "2.0.0")
    {:ok, lease, _} = Lixi.Plugins.Manager.checkout("packaged_fixture", "2.0.0")
    restart_with_snapshot(before_install)

    assert Enum.any?(
             Lixi.Plugins.Manager.catalogue(),
             &(&1.name == "packaged_fixture" and &1.version == "2.0.0")
           )

    assert :ok = Lixi.Plugins.deactivate("packaged_fixture")
    assert {:error, :plugin_in_use} = Lixi.Plugins.remove("packaged_fixture", "2.0.0")
    Lixi.Plugins.Manager.checkin(lease)
    before_remove = :persistent_term.get({Lixi.Plugins.Manager, :catalogue})
    eventually(fn -> Lixi.Plugins.remove("packaged_fixture", "2.0.0") == :ok end)
    restart_with_snapshot(before_remove)
    refute Enum.any?(Lixi.Plugins.Manager.catalogue(), &(&1.name == "packaged_fixture"))
  end

  test "an unavailable compensation blocks mutations and recovers with one retry timer" do
    assert {:ok, descriptor} = Lixi.Plugins.install_package("fixture-2")
    # Recreate a failed durable activation: metadata changed, registry still says inactive.
    assert :ok = Lixi.Cluster.Coordinator.command({:activate_plugin, descriptor})

    :sys.replace_state(
      Lixi.Plugins.Manager,
      &%{&1 | pending: {:deactivate_plugin, "packaged_fixture"}}
    )

    assert :ok = Supervisor.terminate_child(Lixi.Supervisor, Lixi.Cluster.Coordinator)

    try do
      assert {:error, :plugin_recovery_required} = Lixi.Plugins.Manager.recover()
      timer = :sys.get_state(Lixi.Plugins.Manager).recovery_timer
      assert timer != nil
      assert {:error, :plugin_recovery_required} = Lixi.Plugins.Manager.recover()
      assert :sys.get_state(Lixi.Plugins.Manager).recovery_timer == timer
      assert Lixi.Plugins.Manager.status().recovery_required
      assert {:error, :plugin_recovery_required} = Lixi.Plugins.install_package("fixture-1")
    after
      assert {:ok, _} = Supervisor.restart_child(Lixi.Supervisor, Lixi.Cluster.Coordinator)
    end

    assert :ok = Lixi.Plugins.Manager.recover()
    refute Lixi.Plugins.Manager.status().recovery_required

    assert {:error, :plugin_not_found} =
             Lixi.Plugins.request("packaged_fixture", %{method: "GET", path: ["health"]})

    assert {:ok, %{active: []}} = Package.read_registry()
    send(Lixi.Cluster.Member, :heartbeat)
  end

  test "a manager restart preserves a precompiled active version when a package activation was not durable" do
    assert {:ok, _} = Lixi.Plugins.install(Lixi.TestPlugin.PackageLegacy)
    assert :ok = Lixi.Plugins.activate("packaged_fixture", "0.9.0")
    assert {:ok, package} = Lixi.Plugins.install_package("fixture-2")
    previous = :persistent_term.get({Lixi.Plugins.Manager, :catalogue})
    assert :ok = Lixi.Cluster.Coordinator.command({:activate_plugin, package})
    restart_with_snapshot(previous)

    assert {:ok, {:ok, 200, %{label: "legacy"}}} =
             Lixi.Plugins.request("packaged_fixture", %{method: "GET", path: ["health"]})
  end

  test "plugin generation refuses to overwrite a project and failed builds clean their output",
       ctx do
    root = Path.join(ctx.root, "generated")

    Mix.Tasks.Lixi.Plugin.New.run([
      "generated",
      "--module",
      "GeneratedPlugin.V1",
      "--output",
      root
    ])

    source = Path.join(root, "lib/plugin.ex")
    original = File.read!(source)

    assert_raise Mix.Error, fn ->
      Mix.Tasks.Lixi.Plugin.New.run(["generated", "--output", root])
    end

    assert File.read!(source) == original
    File.write!(source, String.replace(original, "name: \"generated\"", "name: \"mismatch\""))
    output = Path.join(ctx.staging, "failed-build")

    assert_raise Mix.Error, ~r/metadata does not match/, fn ->
      Mix.Tasks.Lixi.Plugin.Pack.run([root, "--output", output])
    end

    refute File.exists?(output)
  end

  defp boot(root, expected, marker \\ nil) do
    paths = :code.get_path() |> Enum.flat_map(&["-pa", List.to_string(&1)])

    script = """
    [root, expected, encoded_marker] = System.argv()
    marker = Jason.decode!(encoded_marker)
    Application.load(:lixi)
    Application.put_all_env(lixi: [data_dir: root, cluster_enabled: false, start_server: false,
      max_players: 10, max_workers: 2, max_probe_workers: 2, max_sessions: 10, voice_module: Lixi.TestVoice,
      player_update_interval: 50])
    {:ok, _} = Application.ensure_all_started(:lixi)
    result = Lixi.Plugins.request("packaged_fixture", %{method: "GET", path: ["health"]})
    case {expected, result} do
      {"disabled", {:error, :plugin_not_found}} -> :ok
      {"2.0.0", {:ok, {:ok, 200, %{label: "v2", marker: ^marker}}}} -> :ok
      _ -> raise "Package did not restore"
    end
    IO.puts("PACKAGE_BOOT_OK")
    """

    {output, status} =
      System.cmd(
        "elixir",
        ["--erl", "+S 2:2"] ++ paths ++ ["-e", script, root, expected, Jason.encode!(marker)],
        stderr_to_stdout: true
      )

    assert status == 0, output
    output
  end

  defp restart_with_snapshot(snapshot) do
    :persistent_term.put({Lixi.Plugins.Manager, :catalogue}, snapshot)
    # Consecutive controlled restarts must not count as a production crash storm.
    :ok = Supervisor.terminate_child(Lixi.Supervisor, Lixi.Plugins.Manager)
    {:ok, _} = Supervisor.restart_child(Lixi.Supervisor, Lixi.Plugins.Manager)
    Lixi.Plugins.Manager.catalogue()
  end

  defp copy_package(staging, id, change) do
    File.cp_r!(Path.join(staging, "fixture-1"), Path.join(staging, id))
    file = Path.join([staging, id, "manifest.json"])
    manifest = file |> File.read!() |> Jason.decode!() |> change.()
    File.write!(file, Jason.encode!(manifest))
  end

  defp admin(method, path, body \\ %{}) do
    Plug.Test.conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "youshallnotpass")
    |> put_req_header("x-lixi-admin-token", "package-test-admin-token-012345")
    |> Lixi.Router.call([])
  end

  defp fixture_source(version) do
    """
    defmodule PackagedFixture.V#{version}.Helper do
      def label, do: "v#{version}"
    end
    defmodule PackagedFixture.V#{version} do
      @behaviour Lixi.Plugin
      def metadata, do: %{name: "packaged_fixture", version: "#{version}.0.0", sources: ["packaged_fixture:"]}
      def load("packaged_fixture:demo", config), do: Lixi.Sources.load_builtin(config["uri"])
      def load(_, _), do: %{"loadType" => "empty", "data" => nil}
      def request(%{path: ["wait"]}, _) do
        send(Process.whereis(Lixi.PackageProbe), {:package_waiting, self()})
        receive do :continue -> :ok end
        {:ok, 200, %{label: PackagedFixture.V#{version}.Helper.label()}}
      end
      def request(_, config), do: {:ok, 200, %{label: PackagedFixture.V#{version}.Helper.label(), marker: config["marker"]}}
    end
    """
  end

  defp cleanup_input(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        for name <- File.ls!(path), do: cleanup_input(Path.join(path, name))
        File.rmdir(path)

      {:ok, %{type: :symlink}} ->
        File.rm(path)

      {:ok, %{type: :regular}} ->
        name = Path.basename(path)

        if name in [
             "plugin.ex",
             "plugin.json",
             "manifest.json",
             "README.md",
             "config.example.json",
             ".metadata.json"
           ] or
             (String.ends_with?(name, ".beam") and
                String.starts_with?(name, ["Elixir.PackagedFixture.", "Elixir.GeneratedPlugin."])),
           do: File.rm(path)

      _ ->
        :ok
    end
  end
end
