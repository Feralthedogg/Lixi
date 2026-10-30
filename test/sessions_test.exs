defmodule Lixi.SessionsTest do
  use ExUnit.Case, async: false
  import Lixi.TestHelpers

  test "resume preserves players and replays buffered events only for the same bot" do
    socket =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, id, false, []} = Lixi.Sessions.connect("123", socket)
    assert {:ok, _} = Lixi.Sessions.settings(id, %{"resuming" => true, "timeout" => 1})
    {:ok, player} = Lixi.Sessions.player(id, "456", true)
    Process.exit(socket, :kill)
    eventually(fn -> :sys.get_state(Lixi.Sessions).sessions[id].socket == nil end)
    event = %{op: "event", type: "TrackEndEvent", reason: "finished"}
    Lixi.Sessions.emit(id, event)
    assert {:ok, other, false, []} = Lixi.Sessions.connect("999", self(), id)
    assert other != id
    assert {:ok, ^id, true, [^event]} = Lixi.Sessions.connect("123", self(), id)
    assert {:ok, ^player} = Lixi.Sessions.player(id, "456")
    Process.sleep(1050)
    assert {:ok, ^player} = Lixi.Sessions.player(id, "456")
    Lixi.Sessions.destroy(id, "456")
  end

  test "non-resumable socket disconnect cleans players and bounded buffers expire" do
    socket =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, id, false, []} = Lixi.Sessions.connect("123", socket)
    {:ok, player} = Lixi.Sessions.player(id, "456", true)
    Process.exit(socket, :kill)
    eventually(fn -> not Process.alive?(player) end)
    assert {:error, :not_found} = Lixi.Sessions.user(id)
  end

  test "real HTTP upgrade emits ready and supports Session-Id resume" do
    server = start_supervised!({Bandit, plug: Lixi.Router, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    headers = [
      {"Authorization", "youshallnotpass"},
      {"User-Id", "123"},
      {"Client-Name", "lixi-test/1.0"}
    ]

    url = "ws://127.0.0.1:#{port}/v4/websocket"
    assert {:ok, socket} = Lixi.TestSocket.start(url, self(), headers)

    assert_receive {:websocket, ^socket,
                    %{"op" => "ready", "resumed" => false, "sessionId" => id}},
                   1500

    assert request(:patch, "/v4/sessions/#{id}", %{resuming: true, timeout: 1}).status == 200
    Process.exit(socket, :kill)
    eventually(fn -> :sys.get_state(Lixi.Sessions).sessions[id].socket == nil end)
    assert {:ok, resumed} = Lixi.TestSocket.start(url, self(), [{"Session-Id", id} | headers])

    assert_receive {:websocket, ^resumed,
                    %{"op" => "ready", "resumed" => true, "sessionId" => ^id}},
                   1500

    Process.exit(resumed, :kill)
  end

  test "updating a disconnected session timeout reschedules expiry" do
    socket =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, id, false, []} = Lixi.Sessions.connect("123", socket)
    Lixi.Sessions.settings(id, %{"resuming" => true, "timeout" => 60})
    Process.exit(socket, :kill)
    eventually(fn -> :sys.get_state(Lixi.Sessions).sessions[id].socket == nil end)
    Lixi.Sessions.settings(id, %{"timeout" => 0})
    eventually(fn -> Lixi.Sessions.user(id) == {:error, :not_found} end)
  end
end
