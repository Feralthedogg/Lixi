defmodule Lixi.TrackTest do
  use ExUnit.Case, async: true

  @external "QAAAjQIAJVJpY2sgQXN0bGV5IC0gTmV2ZXIgR29ubmEgR2l2ZSBZb3UgVXAADlJpY2tBc3RsZXlWRVZPAAAAAAADPCAAC2RRdzR3OVdnWGNRAAEAK2h0dHBzOi8vd3d3LnlvdXR1YmUuY29tL3dhdGNoP3Y9ZFF3NHc5V2dYY1EAB3lvdXR1YmUAAAAAAAAAAA=="

  test "decodes an upstream Lavalink v2 envelope" do
    assert {:ok, track} = Lixi.Track.decode(@external)
    assert track["info"]["identifier"] == "dQw4w9WgXcQ"
    assert track["info"]["sourceName"] == "youtube"
    assert track["info"]["length"] == 212_000
  end

  test "version 3 preserves Java modified UTF including NUL and supplementary characters" do
    info = %{
      "identifier" => "/test.wav",
      "isSeekable" => true,
      "author" => "作者",
      "length" => 1000,
      "isStream" => false,
      "position" => 0,
      "title" => "한글\0🎵",
      "uri" => "/test.wav",
      "artworkUrl" => nil,
      "isrc" => nil,
      "sourceName" => "local"
    }

    track = Lixi.Track.new(info, "wav")
    assert {:ok, decoded} = Lixi.Track.decode(track["encoded"])
    assert decoded == track
  end

  test "rejects malformed, truncated and oversized envelopes" do
    for encoded <- [
          nil,
          123,
          "bad",
          "",
          Base.encode64(<<0, 0, 0, 1>>),
          String.duplicate("A", 131_073)
        ] do
      assert {:error, _} = Lixi.Track.decode(encoded)
    end
  end
end
