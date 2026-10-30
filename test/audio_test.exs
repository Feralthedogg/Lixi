defmodule Lixi.AudioTest do
  use ExUnit.Case, async: false
  import Lixi.TestHelpers

  test "actual Rust worker obeys cumulative credits and reports EOF" do
    file = fixture(48_000, 200)
    assert {:ok, worker} = Lixi.Audio.Worker.start(self(), file, 7)
    assert_receive {:audio, ^worker, 7, {:ready, %{"length" => 200}}}, 2000
    refute_receive {:audio, ^worker, 7, {:frame, _}}, 50
    Lixi.Audio.Worker.grant(worker, 5)

    for _ <- 1..5,
        do:
          assert_receive(
            {:audio, ^worker, 7, {:frame, %{opus: opus}}} when byte_size(opus) > 0,
            1000
          )

    Lixi.Audio.Worker.grant(worker, 5)
    refute_receive {:audio, ^worker, 7, {:frame, _}}, 50
    Lixi.Audio.Worker.grant(worker, 15)
    for _ <- 1..5, do: assert_receive({:audio, ^worker, 7, {:frame, _}}, 1000)
    assert_receive {:audio, ^worker, 7, :end}, 1000
    ref = Process.monitor(worker)
    Lixi.Audio.Worker.stop(worker)
    assert_receive {:DOWN, ^ref, _, _, _}, 1000
  end

  test "44.1 kHz is resampled and partial final frames retain their source duration" do
    file = fixture(44_100, 210)
    assert {:ok, worker} = Lixi.Audio.Worker.start(self(), file, 1)
    assert_receive {:audio, ^worker, 1, {:ready, _}}, 2000
    Lixi.Audio.Worker.grant(worker, 20)
    frames = collect(worker, [])
    assert length(frames) == 11
    assert List.last(frames).position == 210
    assert List.last(frames).valid_samples == 480
    Lixi.Audio.Worker.stop(worker)
  end

  test "MP3 decode and seek use the same bounded source interface" do
    wav = fixture(44_100, 1000)
    mp3 = Path.rootname(wav) <> ".mp3"

    assert {_, 0} =
             System.cmd("ffmpeg", ["-v", "error", "-i", wav, "-codec:a", "libmp3lame", mp3],
               stderr_to_stdout: true
             )

    assert {:ok, track} = Lixi.Sources.resolve(mp3)
    assert track["info"]["length"] >= 1000
    assert {:ok, worker} = Lixi.Audio.Worker.start(self(), mp3, 2, position: 400)
    assert_receive {:audio, ^worker, 2, {:ready, _}}, 2000
    Lixi.Audio.Worker.grant(worker, 5)
    assert_receive {:audio, ^worker, 2, {:frame, %{position: position}}}, 2000
    assert position == 420
    Lixi.Audio.Worker.stop(worker)
  end

  test "denies files outside registered roots" do
    assert {:error, _} = Lixi.Sources.resolve("/etc/passwd")
  end

  test "timescale changes output duration while keeping the original position clock" do
    file = fixture(48_000, 1000)

    assert {:ok, worker} =
             Lixi.Audio.Worker.start(self(), file, 1,
               filters: %{"timescale" => %{"speed" => 2.0, "pitch" => 1.1}}
             )

    assert_receive {:audio, ^worker, 1, {:ready, _}}, 2000
    Lixi.Audio.Worker.grant(worker, 25)

    frames =
      for _ <- 1..25 do
        assert_receive {:audio, ^worker, 1, {:frame, frame}}, 2000
        frame
      end

    assert List.last(frames).position == 1000
    Lixi.Audio.Worker.grant(worker, 30)
    assert_receive {:audio, ^worker, 1, :end}, 2000
    Lixi.Audio.Worker.stop(worker)
  end

  defp collect(worker, acc) do
    receive do
      {:audio, ^worker, 1, {:frame, frame}} -> collect(worker, [frame | acc])
      {:audio, ^worker, 1, :end} -> Enum.reverse(acc)
      {:audio, ^worker, 1, {:error, reason}} -> flunk(inspect(reason))
    after
      2000 -> flunk("worker did not reach EOF")
    end
  end
end
