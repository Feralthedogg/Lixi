defmodule Lixi.Admin do
  use Plug.Router
  import Plug.Conn
  plug(:authorize)
  plug(:match)
  plug(:dispatch)

  defp authorize(conn, _) do
    token = Application.get_env(:lixi, :admin_token)
    supplied = List.first(get_req_header(conn, "x-lixi-admin-token"))

    if is_binary(token) and byte_size(token) >= 16 and is_binary(supplied) and
         Plug.Crypto.secure_compare(token, supplied) do
      conn
    else
      conn |> reply(403, %{error: "Admin token required"}) |> halt()
    end
  end

  get("/status", do: reply(conn, 200, Map.merge(Lixi.Lifecycle.status(), Lixi.Upgrade.status())))

  get "/instances" do
    case Lixi.Cluster.instances() do
      {:ok, instances} ->
        nodes =
          Enum.map(instances, fn {instance, info} ->
            %{
              node: Atom.to_string(instance),
              boot: info.boot,
              mode: info.status,
              version: info.version,
              players: info.players,
              maxPlayers: info.max_players,
              plugins: Enum.map(Map.get(info, :plugins, []), &Map.take(&1, [:name, :version]))
            }
          end)

        reply(conn, 200, %{instances: nodes})

      error ->
        result(conn, error)
    end
  end

  post "/drain" do
    Lixi.Lifecycle.drain()
    reply(conn, 200, Lixi.Lifecycle.status())
  end

  post "/resume" do
    case Lixi.Lifecycle.resume() do
      {:ok, _} -> reply(conn, 200, Lixi.Lifecycle.status())
      error -> result(conn, error)
    end
  end

  post "/sessions/:session/move" do
    with true <- is_map(conn.body_params),
         target when is_binary(target) <- conn.body_params["target"],
         {:ok, instances} <- Lixi.Cluster.instances(),
         {instance, _} <-
           Enum.find(instances, fn {instance, _} -> Atom.to_string(instance) == target end) do
      result(conn, Lixi.Sessions.move(session, instance))
    else
      _ -> reply(conn, 400, %{error: "Unknown target instance"})
    end
  end

  get "/plugins" do
    with {:ok, active} <- Lixi.Plugins.active() do
      installed =
        Enum.map(
          Lixi.Plugins.Manager.catalogue(),
          &Map.update!(&1, :hash, fn hash -> Base.encode16(hash, case: :lower) end)
        )

      reply(conn, 200, %{
        active: Enum.map(active, fn {_, d} -> Map.take(d, [:name, :version]) end),
        installed: installed,
        recoveryRequired: Lixi.Plugins.Manager.status().recovery_required
      })
    else
      error -> result(conn, error)
    end
  end

  post "/plugins" do
    body = conn.body_params
    modules = Application.get_env(:lixi, :plugin_modules, [])
    module = if is_map(body), do: Enum.find(modules, &(inspect(&1) == body["module"]))

    if module do
      case Lixi.Plugins.install(module, Map.get(body, "config", %{})) do
        {:ok, descriptor} ->
          reply(conn, 201, Map.update!(descriptor, :hash, &Base.encode16(&1, case: :lower)))

        error ->
          result(conn, error)
      end
    else
      reply(conn, 400, %{error: "Module is not in the plugin allowlist"})
    end
  end

  post "/plugins/packages" do
    body = conn.body_params

    if is_map(body) and is_binary(body["bundle"]) and is_map(Map.get(body, "config", %{})) do
      case Lixi.Plugins.install_package(body["bundle"], Map.get(body, "config", %{})) do
        {:ok, desc} ->
          reply(conn, 201, Map.update!(desc, :hash, &Base.encode16(&1, case: :lower)))

        error ->
          result(conn, error)
      end
    else
      reply(conn, 400, %{error: "A staged bundle id and JSON config are required"})
    end
  end

  post("/plugins/recover", do: result(conn, Lixi.Plugins.Manager.recover()))

  post "/plugins/:name/activate" do
    if is_map(conn.body_params) and is_binary(conn.body_params["version"]),
      do: result(conn, Lixi.Plugins.activate(name, conn.body_params["version"])),
      else: reply(conn, 400, %{error: "version is required"})
  end

  post("/plugins/:name/deactivate", do: result(conn, Lixi.Plugins.deactivate(name)))
  delete("/plugins/:name/:version", do: result(conn, Lixi.Plugins.remove(name, version)))

  post "/upgrade" do
    id = if is_map(conn.body_params), do: conn.body_params["bundle"]

    if is_binary(id) and Regex.match?(~r/^[a-zA-Z0-9_-]{1,64}$/, id) do
      root =
        Application.get_env(
          :lixi,
          :upgrade_root,
          Path.join(Application.fetch_env!(:lixi, :data_dir), "upgrades")
        )

      result(conn, Lixi.Upgrade.apply_bundle(Path.join(root, id)))
    else
      reply(conn, 400, %{error: "A staged bundle id is required"})
    end
  end

  post("/upgrade/rollback", do: result(conn, Lixi.Upgrade.rollback()))
  post("/upgrade/recover", do: result(conn, Lixi.Upgrade.recover()))
  match(_, do: reply(conn, 404, %{error: "Not found"}))

  defp result(conn, :ok), do: reply(conn, 200, %{ok: true})
  defp result(conn, {:ok, value}), do: reply(conn, 200, value)

  defp result(conn, {:error, reason}) do
    status =
      if reason in [
           :unavailable,
           :draining,
           :moving,
           :transfer_pending,
           :transfer_unavailable,
           :plugin_recovery_required
         ],
         do: 503,
         else: 409

    reply(conn, status, %{
      error: if(is_atom(reason), do: Atom.to_string(reason), else: "Operation failed")
    })
  end

  defp reply(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
end
