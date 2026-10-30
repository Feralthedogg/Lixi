Code.require_file("../scripts/validation/watch.exs", __DIR__)

defmodule Lixi.ValidationTest do
  use ExUnit.Case, async: true
  alias Lixi.Validation.Watch

  test "initial progress cannot hide a later disconnect or an unrecovered reconnect" do
    watch = Watch.new(0) |> Watch.delivered()
    assert Watch.passed?(watch)
    watch = Watch.sample(watch, false, 100, 1000)
    refute Watch.passed?(watch)
    refute Watch.expired?(watch, 30_999)
    assert Watch.expired?(watch, 31_000)
    watch = Watch.new(0) |> Watch.delivered() |> Watch.reconnect(1000)
    watch = Watch.sample(watch, true, 100, 2000)
    refute Watch.passed?(watch)
    assert Watch.expired?(watch, 31_000)
    watch = Watch.sample(watch, true, 120, 3000)
    assert Watch.passed?(watch)
    assert Watch.summary(watch).recovered == 1
  end

  test "stopping a healthy run early cannot pass the required duration" do
    watch = Watch.new(0) |> Watch.delivered()

    assert %{completedWindow: false, passed: false} =
             Watch.assessment(watch, 60_000, 1_800_000, 0)

    assert %{completedWindow: true, passed: true} =
             Watch.assessment(watch, 1_800_000, 1_800_000, 0)

    assert %{passed: false} = Watch.assessment(watch, 1_800_000, 1_800_000, 1)
  end

  test "media acquisition does not hide loss of connectivity or mark an idle gap stalled" do
    watch = Watch.new(0) |> Watch.delivered()
    watch = Watch.sample(watch, true, 100, 1000, false)
    watch = Watch.sample(watch, true, 100, 6000, false)
    assert watch.stalled == 0
    watch = Watch.sample(watch, false, 100, 7000, false)
    assert Watch.expired?(watch, 37_000)
    refute Watch.passed?(watch)
  end
end

defmodule Lixi.PlaylistTest do
  use ExUnit.Case, async: true
  Code.require_file("../scripts/validation/playlist.exs", __DIR__)
  alias Lixi.Validation.Playlist

  test "each shuffled round retains every entry and repeats without a boundary duplicate" do
    :rand.seed(:exsss, {1, 2, 3})
    source = Enum.map(1..228, &to_string/1)
    playlist = Playlist.new(source, true)
    {round_one, playlist} = take_round(playlist)
    {round_two, playlist} = take_round(playlist)
    assert Enum.sort(round_one) == Enum.sort(source)
    assert Enum.sort(round_two) == Enum.sort(source)
    refute round_one == source
    refute List.last(round_one) == hd(round_two)
    assert playlist.rounds == 3
  end

  test "single-track and repeated-entry lists continue without losing entries" do
    playlist = Playlist.new(["one"], true)
    assert Playlist.current(Playlist.next(playlist)) == "one"
    {entries, _} = take_round(Playlist.new(["a", "a", "b"], true))
    assert Enum.sort(entries) == ["a", "a", "b"]
    ordered = Playlist.new(["a", "b"], false) |> Playlist.next() |> Playlist.next()
    assert Playlist.current(ordered) == "a"
  end

  defp take_round(playlist) do
    Enum.map_reduce(1..Playlist.size(playlist), playlist, fn _, current ->
      {Playlist.current(current), Playlist.next(current)}
    end)
  end
end
