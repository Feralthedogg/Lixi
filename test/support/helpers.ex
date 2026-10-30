defmodule Lixi.TestVoice do
  use GenServer
  def start(owner, _user, _guild, _voice), do: GenServer.start(__MODULE__, owner)
  def send_frame(pid, frame, epoch, _due), do: GenServer.call(pid, {:frame, frame, epoch})
  def fence(pid, epoch), do: GenServer.call(pid, {:fence, epoch})
  def resume(pid), do: GenServer.call(pid, :resume)
  def quiesce(pid), do: GenServer.call(pid, :quiesce)
  def close(pid), do: GenServer.cast(pid, :close)

  def init(owner) do
    send(owner, {:voice, self(), :ready})

    {:ok,
     %{
       owner: owner,
       monitor: Process.monitor(owner),
       epoch: 0,
       frames: 0,
       position: 0,
       speaking: false,
       silence: 0
     }}
  end

  def handle_call({:fence, epoch}, _, state), do: {:reply, :ok, %{state | epoch: epoch}}
  def handle_call(:resume, _, state), do: {:reply, :ok, %{state | speaking: true}}

  def handle_call(:quiesce, _, state),
    do: {:reply, :ok, %{state | speaking: false, silence: state.silence + 5}}

  def handle_call({:frame, frame, epoch}, _, %{epoch: epoch, speaking: true} = state),
    do: {:reply, :ok, %{state | frames: state.frames + 1, position: frame.position}}

  def handle_call({:frame, _, _}, _, state), do: {:reply, {:error, :not_ready}, state}
  def handle_cast(:close, state), do: {:stop, :normal, state}
  def handle_info({:DOWN, _, _, _, _}, state), do: {:stop, :normal, state}
end

defmodule Lixi.TestSocket do
  use WebSockex

  def start(url, owner, headers),
    do: WebSockex.start(url, __MODULE__, owner, extra_headers: headers)

  def handle_frame({:text, text}, owner) do
    send(owner, {:websocket, self(), Jason.decode!(text)})
    {:ok, owner}
  end

  def handle_disconnect(_, owner), do: {:ok, owner}
end

defmodule Lixi.TestHelpers do
  import ExUnit.Assertions
  import Plug.Test
  import Plug.Conn

  def request(method, path, body \\ nil, authorized \\ true) do
    conn = conn(method, path, if(body == nil, do: "", else: Jason.encode!(body)))
    conn = put_req_header(conn, "content-type", "application/json")
    conn = if authorized, do: put_req_header(conn, "authorization", "youshallnotpass"), else: conn
    Lixi.Router.call(conn, Lixi.Router.init([]))
  end

  def json(conn), do: Jason.decode!(conn.resp_body)

  def session do
    {:ok, id, false, []} = Lixi.Sessions.connect("123", self())
    id
  end

  def fixture(rate \\ 48_000, milliseconds \\ 1000) do
    directory = Path.expand("../tmp/#{Base.encode16(:crypto.strong_rand_bytes(8))}", __DIR__)
    File.mkdir_p!(directory)
    file = Path.join(directory, "tone.wav")
    samples = div(rate * milliseconds, 1000)

    pcm =
      for n <- 0..(samples - 1), into: <<>> do
        value = round(4000 * :math.sin(n * 2 * :math.pi() * 440 / rate))
        <<value::little-signed-16, value::little-signed-16>>
      end

    bytes = byte_size(pcm)

    wav =
      <<"RIFF", bytes + 36::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 2::little-16,
        rate::little-32, rate * 4::little-32, 4::little-16, 16::little-16, "data",
        bytes::little-32, pcm::binary>>

    File.write!(file, wav)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(directory) end)
    file
  end

  def track(path) do
    assert {:ok, track} = Lixi.Sources.resolve(path)
    track
  end

  def voice,
    do: %{
      "token" => "test-token",
      "endpoint" => "voice.discord.media",
      "sessionId" => "discord-session",
      "channelId" => "789"
    }

  def eventually(fun, attempts \\ 100)
  def eventually(fun, 0), do: assert(fun.())

  def eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
