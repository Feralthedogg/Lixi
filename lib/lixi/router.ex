defmodule Lixi.Router do
  use Plug.Router
  use Plug.ErrorHandler
  import Plug.Conn

  plug(:authenticate)
  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 262_144,
    nest_all_json: true
  )

  plug(:unwrap_json)
  plug(:dispatch)

  defp unwrap_json(conn, _), do: %{conn | body_params: Map.get(conn.body_params, "_json", %{})}

  defp authenticate(%{request_path: path} = conn, _)
       when path in ["/version", "/health/live", "/health/ready"], do: conn

  defp authenticate(conn, _) do
    expected = Application.fetch_env!(:lixi, :password)

    case get_req_header(conn, "authorization") do
      [password] ->
        if Plug.Crypto.secure_compare(password, expected),
          do: conn,
          else: conn |> error(401, "Unauthorized") |> halt()

      _ ->
        conn |> error(401, "Unauthorized") |> halt()
    end
  end

  get("/version",
    do: conn |> put_resp_content_type("text/plain") |> send_resp(200, Lixi.Info.version())
  )

  get("/v4/info", do: json(conn, 200, Lixi.Info.get()))
  get("/health/live", do: json(conn, 200, %{status: "up"}))

  get "/health/ready" do
    if Lixi.Cluster.ready?(),
      do: json(conn, 200, %{status: "ready"}),
      else: json(conn, 503, %{status: "not_ready"})
  end

  get("/v4/stats", do: json(conn, 200, Lixi.Info.stats()))
  get("/v4/routeplanner/status", do: send_resp(conn, 204, ""))

  post("/v4/routeplanner/free/address",
    do: error(conn, 500, "Can't access disabled route planner")
  )

  post("/v4/routeplanner/free/all", do: error(conn, 500, "Can't access disabled route planner"))

  get "/v4/websocket" do
    with [user] <- get_req_header(conn, "user-id"),
         true <- snowflake?(user),
         [client] <- get_req_header(conn, "client-name"),
         true <- byte_size(client) <= 200 and String.contains?(client, "/") do
      previous = List.first(get_req_header(conn, "session-id"))

      conn
      |> WebSockAdapter.upgrade(Lixi.WebSocket, {user, previous},
        timeout: 60_000,
        max_frame_size: 65_536
      )
      |> halt()
    else
      _ -> error(conn, 400, "User-Id and Client-Name headers are required")
    end
  end

  get "/v4/loadtracks" do
    conn = fetch_query_params(conn)

    case conn.params["identifier"] do
      identifier when is_binary(identifier) and byte_size(identifier) <= 8192 ->
        json(conn, 200, Lixi.Sources.load(identifier))

      _ ->
        error(conn, 400, "identifier is required")
    end
  end

  get "/v4/decodetrack" do
    conn = fetch_query_params(conn)

    case Lixi.Track.decode(conn.params["encodedTrack"]) do
      {:ok, track} -> json(conn, 200, track)
      {:error, message} -> error(conn, 400, message)
    end
  end

  post "/v4/decodetracks" do
    tracks = conn.body_params

    if is_list(tracks) and length(tracks) <= 100 do
      case Enum.reduce_while(tracks, [], fn encoded, acc ->
             case Lixi.Track.decode(encoded) do
               {:ok, track} -> {:cont, [track | acc]}
               error -> {:halt, error}
             end
           end) do
        {:error, message} -> error(conn, 400, message)
        tracks -> json(conn, 200, Enum.reverse(tracks))
      end
    else
      error(conn, 400, "Expected an array of at most 100 encoded tracks")
    end
  end

  patch "/v4/sessions/:session_id" do
    body = conn.body_params

    if is_map(body) and (not Map.has_key?(body, "resuming") or is_boolean(body["resuming"])) and
         (not Map.has_key?(body, "timeout") or
            (is_integer(body["timeout"]) and body["timeout"] in 0..3600)) do
      case Lixi.Sessions.settings(session_id, body) do
        {:ok, settings} -> json(conn, 200, settings)
        {:error, reason} -> missing(conn, reason)
      end
    else
      error(conn, 400, "Invalid session settings")
    end
  end

  get "/v4/sessions/:session_id/players" do
    with {:ok, players} <- Lixi.Sessions.players(session_id),
         {:ok, snapshots} <- player_snapshots(players) do
      json(conn, 200, snapshots)
    else
      {:error, reason} -> missing(conn, reason)
    end
  end

  get "/v4/sessions/:session_id/players/:guild_id" do
    with {:ok, pid} <- Lixi.Sessions.player(session_id, guild_id),
         {:ok, snapshot} <- Lixi.Player.fetch_snapshot(pid) do
      json(conn, 200, snapshot)
    else
      {:error, reason} -> missing(conn, reason)
    end
  end

  patch "/v4/sessions/:session_id/players/:guild_id" do
    conn = fetch_query_params(conn)

    with true <- snowflake?(guild_id),
         {:ok, _user} <- Lixi.Sessions.user(session_id),
         {:ok, patch} <- Lixi.Player.validate(conn.body_params, false),
         {:ok, player} <-
           update_player(session_id, guild_id, patch, conn.query_params["noReplace"] == "true") do
      json(conn, 200, player)
    else
      false -> error(conn, 400, "Invalid guild id")
      {:error, message} when is_binary(message) -> error(conn, 400, message)
      {:error, reason} -> missing(conn, reason)
    end
  end

  delete "/v4/sessions/:session_id/players/:guild_id" do
    case Lixi.Sessions.destroy(session_id, guild_id) do
      :ok -> send_resp(conn, 204, "")
      {:error, reason} -> missing(conn, reason)
    end
  end

  forward("/v4/lixi", to: Lixi.Admin)

  match "/v4/plugins/:name/*path" do
    conn = fetch_query_params(conn)
    request = %{method: conn.method, path: path, query: conn.query_params, body: conn.body_params}

    case Lixi.Plugins.request(name, request) do
      {:ok, {:ok, status, body}} when status in 200..599 ->
        case Jason.encode(body) do
          {:ok, encoded} when byte_size(encoded) <= 262_144 ->
            conn |> put_resp_content_type("application/json") |> send_resp(status, encoded)

          _ ->
            error(conn, 502, "Invalid plugin response")
        end

      {:error, :plugin_not_found} ->
        error(conn, 404, "Plugin not found")

      _ ->
        error(conn, 502, "Plugin request failed")
    end
  end

  match(_, do: error(conn, 404, "Not found"))

  defp update_player(session, guild, patch, no_replace) do
    skip =
      if no_replace do
        case Lixi.Sessions.player(session, guild) do
          {:ok, pid} -> Lixi.Player.skip_replacement(pid, patch)
          _ -> :continue
        end
      else
        :continue
      end

    case skip do
      {:ok, _} = result ->
        result

      {:error, _} = error ->
        error

      :continue ->
        with {:ok, patch} <- Lixi.Player.resolve_patch(patch),
             {:ok, pid} <- Lixi.Sessions.player(session, guild, true),
             do: Lixi.Player.update(pid, patch, no_replace)
    end
  end

  defp player_snapshots(players) do
    Enum.reduce_while(players, {:ok, []}, fn pid, {:ok, values} ->
      case Lixi.Player.fetch_snapshot(pid) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp missing(conn, :not_found), do: error(conn, 404, "Session not found")
  defp missing(conn, :player_not_found), do: error(conn, 404, "Player not found")
  defp missing(conn, :capacity), do: error(conn, 503, "Capacity reached")
  defp missing(conn, _), do: error(conn, 503, "Player unavailable")
  defp snowflake?(id), do: is_binary(id) and Regex.match?(~r/^[0-9]{1,20}$/, id)

  defp json(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))

  defp error(conn, status, message) do
    body = %{
      timestamp: System.system_time(:millisecond),
      status: status,
      error: Plug.Conn.Status.reason_phrase(status),
      message: message,
      path: conn.request_path
    }

    body =
      if conn.query_string =~ "trace=true",
        do: Map.put(body, :trace, "#{body.error}: #{message}"),
        else: body

    json(conn, status, body)
  end

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{reason: reason}) do
    status = Plug.Exception.status(reason)
    error(conn, status, if(status >= 500, do: "Internal server error", else: "Invalid request"))
  end
end
