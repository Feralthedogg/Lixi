defmodule Lixi.WebSocketTest.Plug do
  def init(options), do: options

  def call(conn, _) do
    conn
    |> WebSockAdapter.upgrade(Lixi.WebSocket, {"123", nil}, timeout: 200)
    |> Plug.Conn.halt()
  end
end

defmodule Lixi.WebSocketTest do
  use ExUnit.Case, async: false

  test "idle clients stay connected by answering server pings" do
    interval = Application.fetch_env!(:lixi, :websocket_ping_interval)
    Application.put_env(:lixi, :websocket_ping_interval, 30)

    server =
      start_supervised!({Bandit, plug: Lixi.WebSocketTest.Plug, port: 0, ip: {127, 0, 0, 1}})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    {:ok, socket} = Lixi.TestSocket.start("ws://127.0.0.1:#{port}", self(), [])

    on_exit(fn ->
      if Process.alive?(socket), do: Process.exit(socket, :kill)
      Application.put_env(:lixi, :websocket_ping_interval, interval)
    end)

    assert_receive {:websocket, ^socket, %{"op" => "ready", "sessionId" => id}}, 1000
    ref = Process.monitor(socket)
    refute_receive {:DOWN, ^ref, _, _, _}, 700
    assert {:ok, "123"} = Lixi.Sessions.user(id)
  end
end
