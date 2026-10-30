defmodule Lixi.RangeFixture do
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, opts) do
    bytes = File.read!(Keyword.fetch!(opts, :file))
    etag = Keyword.get(opts, :etag, "\"v1\"")
    conn = conn |> put_resp_header("etag", etag) |> put_resp_header("accept-ranges", "bytes")

    case {conn.method, get_req_header(conn, "range")} do
      {"HEAD", _} ->
        conn
        |> put_resp_header("content-length", Integer.to_string(byte_size(bytes)))
        |> send_resp(200, "")

      {"GET", [range]} ->
        [_, first, last] = Regex.run(~r/^bytes=(\d+)-(\d+)$/, range)
        first = String.to_integer(first)
        last = String.to_integer(last)

        if Keyword.get(opts, :ignore_range, false) do
          send_resp(conn, 200, bytes)
        else
          conn
          |> put_resp_header("content-range", "bytes #{first}-#{last}/#{byte_size(bytes)}")
          |> send_resp(206, binary_part(bytes, first, last - first + 1))
        end

      _ ->
        send_resp(conn, 404, "")
    end
  end
end

defmodule Lixi.SourceTest do
  use ExUnit.Case, async: false
  import Lixi.TestHelpers

  setup do
    Process.flag(:trap_exit, true)
    old = Application.get_env(:lixi, :http_sources)
    Application.put_env(:lixi, :http_sources, true)
    Application.put_env(:lixi, :http_hosts, ["127.0.0.1"])

    on_exit(fn ->
      Application.put_env(:lixi, :http_sources, old)
      Application.delete_env(:lixi, :http_hosts)
    end)

    :ok
  end

  test "HTTP Range input performs bounded random reads and real Rust decoding" do
    file = fixture()

    server =
      start_supervised!(
        {Bandit, plug: {Lixi.RangeFixture, file: file}, port: 0, ip: {127, 0, 0, 1}}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    uri = "http://127.0.0.1:#{port}/audio.wav?version=1"
    assert {:ok, source} = Lixi.Source.start_link(uri)
    assert {:ok, "RIFF"} = Lixi.Source.read(source, 0, 4)
    assert {:ok, <<_::binary-size(20)>>} = Lixi.Source.read(source, 100, 20)
    assert {:error, :range} = Lixi.Source.read(source, 0, 65_537)
    GenServer.stop(source)
    assert {:ok, track} = Lixi.Sources.resolve(uri)
    assert track["info"]["sourceName"] == "http"
    assert track["info"]["length"] == 1000
  end

  test "a server ignoring Range is rejected without falling back to a full download" do
    server =
      start_supervised!(
        {Bandit,
         plug: {Lixi.RangeFixture, file: fixture(), ignore_range: true},
         port: 0,
         ip: {127, 0, 0, 1}}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    assert {:ok, source} = Lixi.Source.start_link("http://127.0.0.1:#{port}/audio.wav")
    assert {:error, _} = Lixi.Source.read(source, 0, 4)
    GenServer.stop(source)
  end

  test "unlisted HTTP hosts and symlinks are denied" do
    assert {:error, _} = Lixi.Source.start_link("https://example.com/test.wav")
    file = fixture()
    link = file <> ".link"
    File.ln_s!(file, link)
    assert {:error, :source_not_allowed} = Lixi.Source.start_link(link)
  end
end
