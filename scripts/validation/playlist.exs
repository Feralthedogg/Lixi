defmodule Lixi.Validation.Playlist do
  @moduledoc false
  def new(tracks, shuffle) when is_list(tracks) and tracks != [] do
    %{source: tracks, tracks: cycle(tracks, shuffle, nil), shuffle: shuffle, rounds: 1}
  end

  def current(%{tracks: [track | _]}), do: track
  def size(playlist), do: length(playlist.source)

  def next(%{tracks: [_ | remaining]} = playlist) when remaining != [],
    do: %{playlist | tracks: remaining}

  def next(playlist) do
    tracks = cycle(playlist.source, playlist.shuffle, current(playlist))
    %{playlist | tracks: tracks, rounds: playlist.rounds + 1}
  end

  defp cycle(tracks, false, _), do: tracks

  defp cycle(tracks, true, previous) do
    shuffled = Enum.shuffle(tracks)
    # Retain duplicate entries, but avoid the same track at a round boundary
    # when at least one different identifier is available.
    case Enum.split_while(shuffled, &(&1 == previous)) do
      {_, []} -> shuffled
      {prefix, rest} -> rest ++ prefix
    end
  end
end
