defmodule Lixi.Validation.LoadVoice do
  use GenServer
  def start(owner, _, _, _), do: GenServer.start(__MODULE__, owner)

  def init(owner) do
    send(owner, {:voice, self(), :ready})
    {:ok, Process.monitor(owner)}
  end

  def send_frame(_, _, _, _), do: :ok
  def resume(_), do: :ok
  def quiesce(_), do: :ok
  def fence(_, _), do: :ok
  def close(pid), do: GenServer.stop(pid)
  def handle_info({:DOWN, ref, _, _, _}, ref), do: {:stop, :normal, ref}
end

defmodule Lixi.Validation.Load do
  def run do
    streams = System.get_env("LOAD_STREAMS", "10") |> String.to_integer()
    seconds = System.get_env("LOAD_SECONDS", "30") |> String.to_integer()

    if streams not in 1..100 or seconds not in 5..300,
      do: raise("load bounds: 1..100 streams, 5..300 seconds")

    directory = Path.expand("test/tmp/load-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    file = Path.join(directory, "tone.wav")
    # ffmpeg streams fixture generation, avoiding a second full-file PCM allocation.
    {_, 0} =
      System.cmd(
        "ffmpeg",
        [
          "-v",
          "error",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:sample_rate=48000",
          "-t",
          to_string(seconds + 3),
          "-ac",
          "2",
          "-c:a",
          "pcm_s16le",
          file
        ],
        stderr_to_stdout: true
      )

    Application.put_all_env(
      lixi: [
        data_dir: Path.join(directory, "state"),
        source_roots: [directory],
        voice_module: Lixi.Validation.LoadVoice,
        max_workers: streams,
        max_probe_workers: 2,
        start_server: false
      ]
    )

    {:ok, _} = Application.ensure_all_started(:lixi)
    {:ok, track} = Lixi.Sources.resolve(file)
    owner = self()

    socket =
      spawn(fn ->
        ref = Process.monitor(owner)

        drain = fn loop ->
          receive do
            {:DOWN, ^ref, _, _, _} -> :ok
            :stop -> :ok
            _ -> loop.(loop)
          end
        end

        drain.(drain)
      end)

    {:ok, id, _, _} = Lixi.Sessions.connect("123", socket)

    players =
      for n <- 1..streams do
        {:ok, player} = Lixi.Sessions.player(id, to_string(n), :playback)

        {:ok, patch} =
          Lixi.Player.validate(%{
            "track" => %{"encoded" => track["encoded"]},
            "voice" => %{
              "token" => "load",
              "endpoint" => "load.invalid",
              "sessionId" => "load",
              "channelId" => "123"
            }
          })

        {:ok, _} = Lixi.Player.update(player, patch, false)
        player
      end

    started = System.monotonic_time(:millisecond)
    before = Lixi.Metrics.snapshot()

    results =
      Enum.map(1..seconds, fn _ ->
        probes =
          Task.async_stream(
            1..2,
            fn _ ->
              at = System.monotonic_time(:microsecond)
              result = Lixi.Sources.resolve(file)
              {match?({:ok, _}, result), System.monotonic_time(:microsecond) - at}
            end,
            max_concurrency: 2,
            timeout: 15_000
          )
          |> Enum.map(fn {:ok, result} -> result end)

        Process.sleep(1000)
        {Lixi.Metrics.snapshot(), probes}
      end)

    frames = List.last(results) |> elem(0) |> Map.fetch!(:totals)
    probe_results = Enum.flat_map(results, &elem(&1, 1))
    positions = Enum.map(players, &Lixi.Player.snapshot(&1)["state"]["position"])

    report = %{
      streams: streams,
      elapsedMs: System.monotonic_time(:millisecond) - started,
      transport: "simulated Voice; real Rust decode, DSP, credits and Player clock",
      fixture: "48 kHz stereo PCM WAV",
      sent: frames.sent - before.totals.sent,
      late: frames.late - before.totals.late,
      underruns: frames.underruns - before.totals.underruns,
      sendErrors: frames.send_errors - before.totals.send_errors,
      positionsMs: positions,
      probeRequests: length(probe_results),
      probeFailures: Enum.count(probe_results, &(not elem(&1, 0))),
      probeMaxMs: Enum.max(Enum.map(probe_results, &(elem(&1, 1) / 1000))),
      peakNativeRss: Enum.max(Enum.map(results, &elem(&1, 0).nativeRss)),
      peakCpuFraction: Enum.max(Enum.map(results, &elem(&1, 0).cpu)),
      cores: System.schedulers_online()
    }

    Enum.each(1..streams, &Lixi.Sessions.destroy(id, to_string(&1)))
    send(socket, :stop)
    Application.stop(:lixi)
    File.rm!(file)
    output = System.get_env("LOAD_REPORT")
    if output, do: File.write!(output, Jason.encode!(report, pretty: true) <> "\n")
    IO.puts(Jason.encode!(report, pretty: true))

    if report.probeFailures > 0 or report.sendErrors > 0 or
         Enum.any?(positions, &(&1 < seconds * 800)),
       do: System.halt(1)
  end
end

Lixi.Validation.Load.run()
