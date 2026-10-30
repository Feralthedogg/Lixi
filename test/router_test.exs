defmodule Lixi.RouterTest do
  use ExUnit.Case, async: false
  import Lixi.TestHelpers

  test "version is public, all v4 endpoints require authorization" do
    assert request(:get, "/version", nil, false).status == 200
    assert request(:get, "/v4/info", nil, false).status == 401
    info = request(:get, "/v4/info") |> json()
    assert info["version"]["major"] == 4
    assert "local" in info["sourceManagers"]
    assert info["plugins"] == []
    assert request(:get, "/v4/stats").status == 200
    assert request(:get, "/v4/routeplanner/status").status == 204
    assert request(:post, "/v4/routeplanner/free/all").status == 500
    assert Process.whereis(EDA.Supervisor) == nil
  end

  test "load and decode endpoints use Lavalink track and error shapes" do
    path = fixture()
    loaded = request(:get, "/v4/loadtracks?" <> URI.encode_query(%{identifier: path})) |> json()
    assert loaded["loadType"] == "track"
    track = loaded["data"]
    assert track["info"]["length"] == 1000

    assert json(
             request(
               :get,
               "/v4/decodetrack?" <> URI.encode_query(%{encodedTrack: track["encoded"]})
             )
           ) == track

    assert json(request(:post, "/v4/decodetracks", [track["encoded"], track["encoded"]])) == [
             track,
             track
           ]

    assert request(:post, "/v4/decodetracks", ["bad"]).status == 400

    assert json(request(:get, "/v4/loadtracks?identifier=ytsearch:test")) == %{
             "loadType" => "empty",
             "data" => nil
           }

    failure = json(request(:get, "/v4/sessions/missing/players"))
    assert failure["status"] == 404
    assert failure["message"] == "Session not found"
    assert failure["path"] == "/v4/sessions/missing/players"
  end

  test "PATCH creates players and preserves omitted fields, userData and noReplace" do
    id = session()
    path = "/v4/sessions/#{id}/players/456"
    track = fixture() |> track()

    result =
      request(:patch, path, %{
        track: %{encoded: track["encoded"], userData: %{request: 1}},
        paused: true,
        volume: 125
      })

    assert result.status == 200
    assert json(result)["track"]["userData"] == %{"request" => 1}
    assert json(request(:patch, path, %{volume: 75}))["paused"]

    assert json(
             request(:patch, path <> "?noReplace=true", %{
               track: %{encoded: track["encoded"]},
               volume: 50
             })
           )["volume"] == 50

    assert json(request(:get, path))["track"]["userData"] == %{"request" => 1}
    assert json(request(:patch, path, %{track: %{encoded: nil}}))["track"] == nil
    assert request(:patch, path, %{volume: 1001}).status == 400
    assert request(:patch, path, %{track: %{encoded: "bad", identifier: "x"}}).status == 400
    assert request(:delete, path).status == 204
    assert request(:get, path).status == 404
  end

  test "same guild is isolated between sessions and invalid requests do not create a player" do
    first = session()
    second = session()
    a = "/v4/sessions/#{first}/players/456"
    b = "/v4/sessions/#{second}/players/456"
    assert request(:patch, a, %{volume: 200}).status == 200
    assert json(request(:patch, b, %{}))["volume"] == 100
    assert request(:patch, "/v4/sessions/#{first}/players/777", %{paused: "yes"}).status == 400
    assert request(:get, "/v4/sessions/#{first}/players/777").status == 404
  end

  test "noReplace skips resolution and track-specific fields including a null stop" do
    id = session()
    track = fixture() |> track()
    path = "/v4/sessions/#{id}/players/456"

    request(:patch, path, %{
      track: %{encoded: track["encoded"], userData: %{old: true}},
      paused: true
    })

    skipped =
      request(:patch, path <> "?noReplace=true", %{
        track: %{encoded: "invalid-but-skipped", userData: %{new: true}},
        paused: false,
        position: 500,
        volume: 75
      })

    assert skipped.status == 200
    assert json(skipped)["paused"]
    assert json(skipped)["state"]["position"] == 0
    assert json(skipped)["volume"] == 75
    assert json(skipped)["track"]["userData"] == %{"old" => true}

    assert json(request(:patch, path <> "?noReplace=true", %{track: %{encoded: nil}}))["track"] !=
             nil

    assert json(request(:patch, path, %{track: %{encoded: track["encoded"]}}))["paused"] == false
    request(:delete, path)
  end

  test "nullable filter resets and defaults match the v4 protocol" do
    id = session()
    path = "/v4/sessions/#{id}/players/456"
    filters = %{karaoke: nil, rotation: %{}, distortion: %{}, timescale: %{}, pluginFilters: %{}}
    assert json(request(:patch, path, %{filters: filters}))["filters"] == %{}

    result =
      json(request(:patch, path, %{filters: %{vibrato: %{depth: 0.2}, equalizer: [%{band: 1}]}}))

    assert result["filters"]["vibrato"] == %{"depth" => 0.2, "frequency" => 2.0}
    assert result["filters"]["equalizer"] == [%{"band" => 1, "gain" => 1.0}]
    assert request(:patch, path, [1, 2]).status == 400
    request(:delete, path)
  end

  test "malformed JSON returns a Lavalink error response" do
    conn =
      Plug.Test.conn(:patch, "/v4/sessions/x", "{")
      |> Plug.Conn.put_req_header("authorization", "youshallnotpass")
      |> Plug.Conn.put_req_header("content-type", "application/json")

    assert_raise Plug.Parsers.ParseError, fn -> Lixi.Router.call(conn, []) end
  end
end
