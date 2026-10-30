defmodule Lixi.Validation.NativeComparison do
  def run([baseline, candidate]) do
    run = Base.encode16(:crypto.strong_rand_bytes(6))
    directory = Path.expand("test/tmp/native-compare-#{run}")
    runtime = Path.expand("test/runtime/native-compare-#{run}")

    File.mkdir_p!(directory)
    wav = Path.join(directory, "48k.wav")
    wav44 = Path.join(directory, "44k.wav")
    mp3 = Path.join(directory, "audio.mp3")
    webm = Path.join(directory, "audio.webm")

    generate([
      "-f",
      "lavfi",
      "-i",
      "sine=frequency=440:sample_rate=48000",
      "-t",
      "1.21",
      "-ac",
      "2",
      "-c:a",
      "pcm_s16le",
      wav
    ])

    generate(["-i", wav, "-ar", "44100", wav44])
    generate(["-i", wav, "-ar", "44100", "-c:a", "libmp3lame", mp3])
    generate(["-i", wav, "-c:a", "libopus", webm])

    Application.put_all_env(
      lixi: [
        source_roots: [directory],
        start_server: false,
        data_dir: runtime
      ]
    )

    {:ok, _} = Application.ensure_all_started(:lixi)

    try do
      results =
        for file <- [wav, wav44, mp3, webm],
            options <- [
              [],
              [position: 400, gain: 0.5, filters: %{"timescale" => %{"speed" => 1.5}}]
            ] do
          before = decode(baseline, file, options)
          after_result = decode(candidate, file, options)

          if before != after_result,
            do: raise("Native output changed for #{Path.basename(file)} with #{inspect(options)}")

          %{
            source: Path.basename(file),
            seek: options[:position] || 0,
            frames: before.frames,
            validSamples: before.samples,
            byteIdentical: true
          }
        end

      IO.puts(Jason.encode!(%{comparisons: results}, pretty: true))
    after
      Application.stop(:lixi)
      File.rm_rf!(directory)
      File.rm_rf!(runtime)
    end
  end

  defp generate(arguments) do
    case System.cmd("ffmpeg", ["-v", "error" | arguments], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> raise("Could not generate comparison fixture")
    end
  end

  defp decode(executable, file, options) do
    Application.put_env(:lixi, :audio_executable, Path.expand(executable))
    {:ok, worker} = Lixi.Audio.Worker.start(self(), file, 1, options)

    try do
      metadata =
        receive do
          {:audio, ^worker, 1, {:ready, metadata}} -> Map.delete(metadata, :source_version)
        after
          5000 -> raise("Native comparison metadata timed out")
        end

      Lixi.Audio.Worker.grant(worker, 25)
      frames = collect(worker, [], 0)

      bytes =
        Enum.map(frames, fn frame ->
          <<frame.position::64, frame.valid_samples::16, frame.opus::binary>>
        end)

      %{
        metadata: metadata,
        frames: length(frames),
        samples: Enum.sum(Enum.map(frames, & &1.valid_samples)),
        hash: :crypto.hash(:sha256, bytes)
      }
    after
      Lixi.Audio.Worker.stop(worker)
    end
  end

  defp collect(worker, frames, count) do
    receive do
      {:audio, ^worker, 1, {:frame, frame}} ->
        count = count + 1
        if rem(count, 10) == 0, do: Lixi.Audio.Worker.grant(worker, count + 25)
        collect(worker, [frame | frames], count)

      {:audio, ^worker, 1, :end} ->
        Enum.reverse(frames)

      {:audio, ^worker, 1, {:error, _}} ->
        raise("Native comparison decode failed")
    after
      5000 -> raise("Native comparison output timed out")
    end
  end
end

Lixi.Validation.NativeComparison.run(System.argv())
