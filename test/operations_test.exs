defmodule Lixi.OperationsTest do
  use ExUnit.Case, async: false
  import Lixi.TestHelpers
  import Plug.Conn

  setup do
    token = Application.get_env(:lixi, :admin_token)
    Application.put_env(:lixi, :admin_token, "operations-test-token-0123456789")

    on_exit(fn ->
      Application.put_env(:lixi, :admin_token, token)
      Lixi.Lifecycle.resume()
    end)

    :ok
  end

  defp admin(method, path, body \\ %{}) do
    Plug.Test.conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "youshallnotpass")
    |> put_req_header("x-lixi-admin-token", "operations-test-token-0123456789")
    |> Lixi.Router.call([])
  end

  test "management mutations require a separate token and drain preserves existing control" do
    id = session()
    path = "/v4/sessions/#{id}/players/456"
    assert request(:patch, path, %{}).status == 200
    assert request(:post, "/v4/lixi/drain", %{}).status == 403
    assert admin(:post, "/v4/lixi/drain").status == 200
    assert request(:get, "/health/ready", nil, false).status == 503
    assert request(:get, "/health/live", nil, false).status == 200
    assert request(:patch, path, %{volume: 125}).status == 200
    assert {:error, :draining} = Lixi.Sessions.connect("new-bot", self())
    assert request(:patch, "/v4/sessions/#{id}/players/789", %{}).status == 503
    assert admin(:post, "/v4/lixi/upgrade", %{bundle: "../outside"}).status == 400
    assert admin(:post, "/v4/lixi/plugins", %{module: "File", config: %{}}).status == 400
    request(:delete, path)
  end

  test "staged imports with a confirmed missing session release local capacity" do
    session = %{
      user: "123",
      socket: nil,
      monitor: nil,
      resuming: true,
      timeout: 60,
      timer: nil,
      generation: make_ref(),
      events: :queue.new(),
      event_count: 0,
      players: %{}
    }

    id = "abandoned-import"

    assert {:ok, _} =
             GenServer.call(Lixi.Sessions, {:prepare_import, id, session, self(), 0, make_ref()})

    send(Lixi.Sessions, {:reconcile_move, id})
    eventually(fn -> not Map.has_key?(:sys.get_state(Lixi.Sessions).sessions, id) end)
  end
end
