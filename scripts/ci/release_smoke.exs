defmodule Lixi.CI.Socket do
  use WebSockex

  def start(url, owner, headers),
    do: WebSockex.start(url, __MODULE__, owner, extra_headers: headers)

  def handle_frame({:text, body}, owner) do
    send(owner, {:ci_socket, Jason.decode!(body)})
    {:ok, owner}
  end

  def handle_disconnect(_, owner), do: {:ok, owner}
end

defmodule Lixi.CI.ReleaseSmoke do
  def run do
    mode = System.fetch_env!("LIXI_CI_SMOKE_MODE")
    true = mode in ["install", "restore"]
    {:ok, _} = Application.ensure_all_started(:lixi)

    try do
      check!(EDA.Voice.Dave.Native.available?(), "packaged DAVE NIF")
      check!(EDA.Voice.Dave.Native.max_protocol_version() >= 1, "DAVE protocol")
      applications = Application.started_applications() |> Enum.map(&elem(&1, 0))
      check!(:eda not in applications and :ra not in applications, "headless standalone startup")
      executable = Path.join(:code.priv_dir(:lixi), "bin/lixi-audio")
      {:ok, stat} = File.stat(executable)

      check!(
        stat.type == :regular and Bitwise.band(stat.mode, 0o111) != 0,
        "packaged audio executable"
      )

      {_, listener, _, _} =
        Enum.find(Supervisor.which_children(Lixi.Supervisor), fn {id, _, _, _} ->
          match?({Bandit, _}, id)
        end)

      {:ok, {_, port}} = ThousandIsland.listener_info(listener)
      origin = "http://127.0.0.1:#{port}"
      {200, version} = request(origin, :get, "/version", :public)
      check!(version == Lixi.Info.version(), "version endpoint")
      {200, _} = request(origin, :get, "/health/ready", :public)
      {401, _} = request(origin, :get, "/v4/info", :public)
      {403, _} = request(origin, :get, "/v4/lixi/status", :client)

      if mode == "install" do
        {404, _} = request(origin, :get, "/v4/plugins/radio/health", :client)

        {201, installed} =
          request(origin, :post, "/v4/lixi/plugins/packages", :admin, %{
            bundle: "radio-1.0.0",
            config: %{tracks: %{}}
          })

        check!(byte_size(Jason.decode!(installed)["package"]) == 64, "installed package identity")

        {200, _} =
          request(origin, :post, "/v4/lixi/plugins/radio/activate", :admin, %{version: "1.0.0"})
      end

      {200, health} = request(origin, :get, "/v4/plugins/radio/health", :client)

      check!(
        Jason.decode!(health) == %{"name" => "radio", "version" => "1.0.0", "tracks" => 0},
        "restored plugin callback"
      )

      {200, info} = request(origin, :get, "/v4/info", :client)

      check!(
        %{"name" => "radio", "version" => "1.0.0"} in Jason.decode!(info)["plugins"],
        "plugin capability advertisement"
      )

      {200, catalogue} = request(origin, :get, "/v4/lixi/plugins", :admin)
      check!(Jason.decode!(catalogue)["recoveryRequired"] == false, "plugin recovery state")

      media = fixture(mode)
      Application.put_env(:lixi, :source_roots, [Path.dirname(media)])

      {200, loaded} =
        request(origin, :get, "/v4/loadtracks?identifier=" <> URI.encode_www_form(media), :client)

      track = Jason.decode!(loaded)

      check!(
        track["loadType"] == "track" and track["data"]["info"]["length"] > 0,
        "packaged native decode"
      )

      exercise_session(origin, port, track["data"]["encoded"])
      IO.puts("RELEASE_SMOKE_OK mode=#{mode} version=#{Lixi.Upgrade.version()}")
    after
      Application.stop(:lixi)
    end
  end

  defp exercise_session(origin, port, encoded) do
    headers = [
      {"Authorization", System.fetch_env!("LIXI_PASSWORD")},
      {"User-Id", "123"},
      {"Client-Name", "lixi-ci/1.0"}
    ]

    {:ok, socket} = Lixi.CI.Socket.start("ws://127.0.0.1:#{port}/v4/websocket", self(), headers)

    try do
      session =
        receive do
          {:ci_socket, %{"op" => "ready", "sessionId" => session}} -> session
        after
          10_000 -> raise "WebSocket ready deadline exceeded"
        end

      player = "/v4/sessions/#{session}/players/456"
      {200, _} = request(origin, :patch, player, :client, %{track: %{encoded: encoded}})
      {200, body} = request(origin, :get, player, :client)
      check!(Jason.decode!(body)["track"]["encoded"] == encoded, "Player track round trip")
      {200, _} = request(origin, :post, "/v4/lixi/drain", :admin)
      {503, _} = request(origin, :get, "/health/ready", :public)
      {200, _} = request(origin, :get, "/health/live", :public)
      {200, _} = request(origin, :patch, player, :client, %{volume: 125})
      {503, _} = request(origin, :patch, "/v4/sessions/#{session}/players/789", :client, %{})
      {204, _} = request(origin, :delete, player, :client)
      {200, _} = request(origin, :post, "/v4/lixi/resume", :admin)
      {200, _} = request(origin, :get, "/health/ready", :public)
    after
      if Process.alive?(socket), do: Process.exit(socket, :kill)
    end
  end

  defp fixture(mode) do
    path = Path.expand("test/runtime/ci-release-media/tone-#{mode}.wav")
    File.mkdir_p!(Path.dirname(path))
    samples = 12_000
    pcm = :binary.copy(<<0::little-signed-16, 0::little-signed-16>>, samples)
    bytes = byte_size(pcm)

    wave =
      <<"RIFF", bytes + 36::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 2::little-16,
        48_000::little-32, 192_000::little-32, 4::little-16, 16::little-16, "data",
        bytes::little-32, pcm::binary>>

    case File.read(path) do
      {:ok, ^wave} -> :ok
      {:error, :enoent} -> File.write!(path, wave, [:exclusive])
      _ -> raise "CI fixture path contains unexpected data"
    end

    path
  end

  defp request(origin, method, path, authentication, body \\ %{}) do
    headers =
      case authentication do
        :public ->
          []

        :client ->
          [{~c"authorization", String.to_charlist(System.fetch_env!("LIXI_PASSWORD"))}]

        :admin ->
          [
            {~c"authorization", String.to_charlist(System.fetch_env!("LIXI_PASSWORD"))},
            {~c"x-lixi-admin-token", String.to_charlist(System.fetch_env!("LIXI_ADMIN_TOKEN"))}
          ]
      end

    url = String.to_charlist(origin <> path)

    request =
      if method in [:post, :patch],
        do: {url, headers, ~c"application/json", Jason.encode!(body)},
        else: {url, headers}

    http_options = [timeout: 15_000, connect_timeout: 5_000, autoredirect: false]
    response_options = [body_format: :binary]

    {:ok, {{_, status, _}, _, response}} =
      :httpc.request(method, request, http_options, response_options)

    {status, response}
  end

  defp check!(true, _), do: :ok
  defp check!(false, operation), do: raise("Release smoke failed: #{operation}")
end

Lixi.CI.ReleaseSmoke.run()
