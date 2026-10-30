Code.require_file("watch.exs", __DIR__)
Code.require_file("playlist.exs", __DIR__)

defmodule Lixi.Validation.Socket do
  use WebSockex

  def handle_frame({:text, body}, owner) do
    send(owner, {:lavalink, Jason.decode!(body)})
    {:ok, owner}
  end

  def handle_cast(:close, owner), do: {:close, owner}

  def handle_disconnect(info, owner) do
    code =
      case info do
        %{reason: {:remote, code, _}} when is_integer(code) -> code
        _ -> "unknown"
      end

    send(owner, {:lavalink_disconnected, code})
    {:ok, owner}
  end
end

defmodule Lixi.Validation.Consumer do
  @behaviour EDA.Consumer
  def handle_event({type, data})
      when type in [:READY, :VOICE_STATE_UPDATE, :VOICE_SERVER_UPDATE] do
    if owner = Process.whereis(:lixi_validation), do: send(owner, {:discord, type, data})
    :ok
  end

  def handle_event(_), do: :ok
end

defmodule Lixi.Validation.Soak do
  alias Lixi.Validation.{Playlist, Watch}

  def run([file | arguments]) do
    config =
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(String.trim(line), "=", parts: 2) do
          [key, value] -> Map.put(acc, key, String.trim(value, "\""))
          _ -> acc
        end
      end)

    token = config["DISCORD_BOT_TOKEN"] || ""
    guild = config["DISCORD_GUILD_ID"] || ""
    channel = config["DISCORD_CHANNEL_ID"] || ""

    if token == "",
      do: raise("Fill DISCORD_BOT_TOKEN in the private .env; never paste it into chat")

    for id <- [guild, channel] do
      {number, ""} = Integer.parse(id)

      if Bitwise.bsr(number, 22) + 1_420_070_400_000 > System.system_time(:millisecond),
        do: raise("Discord guild/channel ID has a future creation time")
    end

    for app <- [:inets, :ssl, :jason], do: Application.ensure_all_started(app)
    headers = [{~c"authorization", String.to_charlist("Bot " <> token)}]
    bot = request!(:get, "https://discord.com/api/v10/users/@me", headers)
    target = request!(:get, "https://discord.com/api/v10/channels/" <> channel, headers)

    if bot["bot"] != true or target["guild_id"] != guild or target["type"] != 2,
      do: raise("Target must be a voice channel in the configured bot's guild")

    if "--check" in arguments do
      IO.puts("Bot identity and target voice channel verified; no voice connection was opened")
    else
      soak(config, bot["id"], Path.dirname(Path.expand(file)), "--loop" in arguments)
    end
  end

  defp soak(config, bot, private, repeat) do
    Process.register(self(), :lixi_validation)
    owner = self()
    System.trap_signal(:sigterm, fn -> send(owner, :validation_stop) end)
    origin = config["LIXI_URL"] || "http://127.0.0.1:2333"
    password = Map.fetch!(config, "LIXI_PASSWORD")
    headers = [{"Authorization", password}, {"User-Id", bot}, {"Client-Name", "lixi-soak/1.0"}]
    url = String.replace_prefix(origin, "http", "ws") <> "/v4/websocket"

    socket =
      case WebSockex.start(url, Lixi.Validation.Socket, self(), extra_headers: headers) do
        {:ok, pid} -> pid
        _ -> raise("Lixi websocket connection failed")
      end

    session =
      receive do
        {:lavalink, %{"op" => "ready", "sessionId" => id}} -> id
      after
        10_000 -> raise("Lixi websocket did not become ready")
      end

    extractor = Path.join(private, "tools/yt-dlp")

    playlist =
      case config["YOUTUBE_PLAYLIST_URL"] do
        url when is_binary(url) and url != "" ->
          media_command(["playlist", url, "--extractor", extractor])["tracks"]

        _ ->
          Map.fetch!(config, "PLAYLIST_FILE") |> File.read!() |> Jason.decode!()
      end

    if not is_list(playlist) or playlist == [] or length(playlist) > 1000 or
         Enum.any?(playlist, &(not is_binary(&1))),
       do: raise("Playlist must contain 1..1000 supported identifiers")

    media_dir = Path.join(private, "media/soak-#{Base.encode16(:crypto.strong_rand_bytes(8))}")
    :ok = File.mkdir(media_dir)
    seconds = String.to_integer(config["SOAK_DURATION_SECONDS"] || "1800")
    reconnect = String.to_integer(config["RECONNECT_INTERVAL_SECONDS"] || "300")

    if seconds not in 30..86_400 or reconnect not in 30..3600,
      do: raise("Soak duration/reconnect interval outside bounds")

    Application.put_all_env(
      eda: [
        token: Map.fetch!(config, "DISCORD_BOT_TOKEN"),
        consumer: Lixi.Validation.Consumer,
        intents: [:guilds, :guild_voice_states],
        shards: 1
      ]
    )

    Logger.configure(level: :warning)

    case Application.ensure_all_started(:eda) do
      {:ok, _} -> :ok
      _ -> raise("EDA Gateway startup failed")
    end

    guild = Map.fetch!(config, "DISCORD_GUILD_ID")
    channel = Map.fetch!(config, "DISCORD_CHANNEL_ID")
    endpoint = origin <> "/v4/sessions/#{session}/players/#{guild}"
    auth = [{~c"authorization", String.to_charlist(password)}]
    started = System.monotonic_time(:millisecond)

    state = %{
      config: config,
      origin: origin,
      auth: auth,
      endpoint: endpoint,
      guild: guild,
      channel: channel,
      bot: bot,
      playlist:
        Playlist.new(
          playlist,
          "--shuffle" in System.argv() or config["SHUFFLE_PLAYLIST"] == "true"
        ),
      extractor: extractor,
      media_dir: media_dir,
      media_file: nil,
      media_task: nil,
      source_failures: 0,
      consecutive_failures: 0,
      voice_session: nil,
      voice_server: nil,
      joined: false,
      leave_pending: false,
      join_deadline: started + 30_000,
      first_frame: nil,
      startup_deadline: started + 150_000,
      until: if(repeat, do: :infinity, else: :starting),
      duration_ms: seconds * 1000,
      checkpoint_due: :pending,
      next_reconnect: :pending,
      reconnect_ms:
        if(not repeat or "--reconnect-test" in System.argv(), do: reconnect * 1000, else: 0),
      tracks: 0,
      exceptions: 0,
      close_events: 0,
      metrics: nil,
      next_poll: started,
      watch: Watch.new(started)
    }

    try do
      receive do
        {:discord, :READY, _} -> :ok
      after
        30_000 -> raise("EDA Gateway did not become ready")
      end

      EDA.Gateway.Connection.update_voice_state(guild, channel, self_mute: false, self_deaf: true)
      result = loop(state)

      report =
        result
        |> Map.take([:tracks, :source_failures, :exceptions, :close_events, :metrics])
        |> Map.merge(Watch.summary(result.watch))
        |> Map.put(
          :elapsedSeconds,
          div(System.monotonic_time(:millisecond) - (result.first_frame || started), 1000)
        )
        |> Map.put(
          :daveCoverage,
          "Protocol counters are observed; participant churn and remote audibility need independent verification"
        )
        |> Map.put(:passed, Watch.passed?(result.watch) and result.exceptions == 0)

      write_report(private, report)
    rescue
      error ->
        write_report(private, %{
          passed: false,
          error: Exception.message(error),
          elapsedSeconds: div(System.monotonic_time(:millisecond) - started, 1000)
        })

        reraise error, __STACKTRACE__
    after
      if task = Process.get(:media_task), do: Task.shutdown(task, :brutal_kill)

      try do
        request!(:delete, endpoint, auth)
      rescue
        _ -> :ok
      end

      EDA.Gateway.Connection.update_voice_state(guild, nil, self_mute: false, self_deaf: true)
      WebSockex.cast(socket, :close)
      Application.stop(:eda)
      File.rm_rf!(media_dir)
    end
  end

  defp loop(state) do
    now = System.monotonic_time(:millisecond)

    cond do
      is_integer(state.until) and now >= state.until ->
        state

      state.first_frame == nil and now >= state.startup_deadline and state.until == :infinity ->
        IO.puts("Waiting for a DAVE group and media recipient")
        loop(%{state | startup_deadline: now + 300_000})

      state.first_frame == nil and now >= state.startup_deadline ->
        raise("No media delivered before startup deadline")

      state.until == :infinity and is_integer(state.checkpoint_due) and
          now >= state.checkpoint_due ->
        report =
          Map.merge(Watch.summary(state.watch), %{
            passed: Watch.passed?(state.watch) and state.exceptions == 0,
            elapsedSeconds: div(now - state.first_frame, 1000),
            tracks: state.tracks,
            source_failures: state.source_failures,
            rounds: state.playlist.rounds,
            shuffled: state.playlist.shuffle,
            metrics: state.metrics,
            daveCoverage: "Protocol counters observed; receiver listening confirmed separately"
          })

        write_report(Path.dirname(state.media_dir) |> Path.dirname(), report)
        loop(%{state | checkpoint_due: now + state.duration_ms})

      not state.joined and now >= state.join_deadline ->
        raise("Discord voice join/rejoin timed out")

      state.first_frame != nil and Watch.expired?(state.watch, now) ->
        raise("Voice did not recover media delivery within 30 seconds")

      is_integer(state.next_reconnect) and now >= state.next_reconnect and not state.leave_pending ->
        EDA.Gateway.Connection.update_voice_state(state.guild, nil,
          self_mute: false,
          self_deaf: true
        )

        loop(%{
          state
          | voice_session: nil,
            voice_server: nil,
            joined: false,
            leave_pending: true,
            join_deadline: now + 30_000,
            next_reconnect: now + state.reconnect_ms,
            watch: Watch.reconnect(state.watch, now)
        })

      state.joined and state.tracks > 0 and now >= state.next_poll ->
        poll(state, now) |> loop()

      true ->
        receive do
          message -> handle(message, state, now) |> loop()
        after
          250 -> loop(state)
        end
    end
  end

  defp poll(state, now) do
    player = request!(:get, state.endpoint, state.auth)
    position = get_in(player, ["state", "position"])
    connected = get_in(player, ["state", "connected"]) == true

    metrics =
      case state.config["LIXI_ADMIN_TOKEN"] do
        token when is_binary(token) and byte_size(token) >= 16 ->
          request!(:get, state.origin <> "/v4/lixi/metrics", [
            {~c"x-lixi-admin-token", String.to_charlist(token)} | state.auth
          ])

        _ ->
          nil
      end

    %{
      state
      | watch: Watch.sample(state.watch, connected, position, now, state.media_task == nil),
        metrics: metrics,
        next_poll: now + 5000
    }
  end

  defp handle({:discord, :VOICE_STATE_UPDATE, data}, state, _) do
    if data["guild_id"] == state.guild and data["user_id"] == state.bot do
      cond do
        data["channel_id"] == nil and state.leave_pending ->
          EDA.Gateway.Connection.update_voice_state(state.guild, state.channel,
            self_mute: false,
            self_deaf: true
          )

          %{state | leave_pending: false, voice_session: nil, voice_server: nil}

        data["channel_id"] == state.channel ->
          participants = length(EDA.Cache.VoiceState.for_channel(state.guild, state.channel))
          IO.puts("Voice participants observed: #{participants}")
          attach(%{state | voice_session: data["session_id"]})

        true ->
          state
      end
    else
      state
    end
  end

  defp handle({:discord, :VOICE_SERVER_UPDATE, data}, state, _) do
    if data["guild_id"] == state.guild and data["endpoint"],
      do: attach(%{state | voice_server: data}),
      else: state
  end

  defp handle({:lavalink, %{"type" => "TrackStartEvent"}}, state, now) do
    state =
      if state.first_frame == nil do
        %{
          state
          | first_frame: now,
            until: if(state.until == :infinity, do: :infinity, else: now + state.duration_ms),
            checkpoint_due: now + state.duration_ms,
            next_reconnect:
              if(state.reconnect_ms > 0, do: now + state.reconnect_ms, else: :disabled)
        }
      else
        state
      end

    %{state | watch: Watch.delivered(state.watch)}
  end

  defp handle({:lavalink, %{"type" => "TrackEndEvent", "reason" => reason}}, state, _)
       when reason in ["finished", "loadFailed"] do
    state =
      if reason == "loadFailed", do: %{state | exceptions: state.exceptions + 1}, else: state

    play(%{
      state
      | playlist: Playlist.next(state.playlist),
        watch: %{state.watch | last_position: nil}
    })
  end

  defp handle({:lavalink, %{"type" => "TrackExceptionEvent"}}, state, _),
    do: %{state | exceptions: state.exceptions + 1}

  defp handle({:lavalink, %{"type" => "WebSocketClosedEvent"}}, state, _),
    do: %{state | close_events: state.close_events + 1}

  defp handle({ref, result}, %{media_task: %{ref: ref}} = state, _) do
    Process.demonitor(ref, [:flush])
    Process.delete(:media_task)
    state = %{state | media_task: nil}

    case result do
      {:ok, identifier, media_file} ->
        request!(:patch, state.endpoint, state.auth, %{track: %{identifier: identifier}})
        %{state | tracks: state.tracks + 1, media_file: media_file, consecutive_failures: 0}

      :error ->
        if state.consecutive_failures + 1 >= Playlist.size(state.playlist),
          do: raise("No playlist media could be acquired")

        play(%{
          state
          | playlist: Playlist.next(state.playlist),
            source_failures: state.source_failures + 1,
            consecutive_failures: state.consecutive_failures + 1
        })
    end
  end

  defp handle(:validation_stop, state, now), do: %{state | until: now}

  defp handle({:lavalink_disconnected, code}, _, _), do: raise("Lixi WebSocket closed: #{code}")
  defp handle(_, state, _), do: state

  defp attach(%{joined: false, voice_session: session, voice_server: server} = state)
       when is_binary(session) and is_map(server) do
    request!(:patch, state.endpoint, state.auth, %{
      voice: %{
        sessionId: session,
        token: server["token"],
        endpoint: server["endpoint"],
        channelId: state.channel
      }
    })

    state = %{state | joined: true}
    if state.tracks == 0 and state.media_task == nil, do: play(state), else: state
  end

  defp attach(state), do: state

  defp play(%{media_task: task} = state) when task != nil, do: state

  defp play(state) do
    if state.media_file, do: File.rm!(state.media_file)
    identifier = Playlist.current(state.playlist)

    task =
      Task.async(fn ->
        try do
          if String.starts_with?(identifier, "https://www.youtube.com/watch?") do
            %{"path" => path} =
              media_command([
                "download",
                identifier,
                "--extractor",
                state.extractor,
                "--directory",
                state.media_dir
              ])

            {:ok, path, path}
          else
            {:ok, identifier, nil}
          end
        rescue
          _ -> :error
        end
      end)

    Process.put(:media_task, task)
    %{state | media_task: task, media_file: nil}
  end

  defp write_report(private, report) do
    directory = Path.join(private, "reports")
    File.mkdir_p!(directory)
    file = Path.join(directory, "soak-#{System.system_time(:second)}.json")
    File.write!(file, Jason.encode!(report, pretty: true) <> "\n")
    IO.puts("Soak report: #{file}; passed=#{report.passed}")
  end

  defp media_command(arguments) do
    case System.cmd("python3", [Path.join(__DIR__, "youtube_media.py") | arguments],
           stderr_to_stdout: true
         ) do
      {output, 0} -> Jason.decode!(output)
      _ -> raise("YouTube acquisition failed")
    end
  end

  defp request!(method, url, headers, body \\ nil) do
    request =
      if body == nil,
        do: {String.to_charlist(url), headers},
        else: {String.to_charlist(url), headers, ~c"application/json", Jason.encode!(body)}

    options = [
      timeout: 15_000,
      connect_timeout: 5000,
      autoredirect: false,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    case :httpc.request(method, request, options, body_format: :binary) do
      {:ok, {{_, status, _}, _, data}} when status in 200..299 ->
        if data == "", do: %{}, else: Jason.decode!(data)

      {:ok, {{_, status, _}, _, _}} ->
        raise("HTTP #{status} for #{method} #{URI.parse(url).path} during validation")

      _ ->
        raise("HTTP transport failed during validation")
    end
  end
end

Lixi.Validation.Soak.run(System.argv())
