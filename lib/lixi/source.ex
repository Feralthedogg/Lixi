defmodule Lixi.Source do
  @moduledoc "Owns source handles and serves bounded, version-checked random reads."
  use GenServer

  def start_link(identifier), do: GenServer.start_link(__MODULE__, identifier)
  def describe(pid), do: GenServer.call(pid, :describe)
  def read(pid, offset, length), do: GenServer.call(pid, {:read, offset, length}, 7_000)

  @impl true
  def init(identifier) do
    case open(identifier) do
      {:ok, source} -> {:ok, source}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:describe, _, state), do: {:reply, Map.drop(state, [:file]), state}

  def handle_call({:read, offset, length}, _, state)
      when is_integer(offset) and offset >= 0 and length in 1..65_536 do
    result =
      if offset + length <= state.length,
        do: read_source(state, offset, length),
        else: {:error, :range}

    {:reply, result, state}
  end

  def handle_call({:read, _, _}, _, state), do: {:reply, {:error, :range}, state}

  @impl true
  def terminate(_, %{file: file}), do: :file.close(file)
  def terminate(_, _), do: :ok

  defp open(identifier) do
    uri = URI.parse(identifier)

    cond do
      uri.scheme in ["http", "https"] ->
        open_http(uri)

      uri.scheme == nil or uri.scheme == "file" ->
        open_file(if(uri.scheme, do: URI.decode(uri.path || ""), else: identifier))

      true ->
        {:error, :unsupported_source}
    end
  end

  defp open_file(path) do
    path = Path.expand(path)
    roots = Application.fetch_env!(:lixi, :source_roots) |> Enum.map(&Path.expand/1)
    allowed = Enum.any?(roots, &(path == &1 or String.starts_with?(path, &1 <> "/")))

    with true <- allowed and no_symlinks?(path),
         {:ok, stat} <- File.stat(path, time: :posix),
         true <- stat.type == :regular and stat.size > 0,
         {:ok, file} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok,
       %{
         kind: :file,
         file: file,
         identifier: path,
         length: stat.size,
         version: {stat.inode, stat.size, stat.mtime},
         extension: extension(path)
       }}
    else
      false -> {:error, :source_not_allowed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp no_symlinks?(path) do
    [_root | parts] = Path.split(path)

    parts
    |> Enum.reduce_while("/", fn part, parent ->
      current = Path.join(parent, part)

      case File.lstat(current) do
        {:ok, %{type: :symlink}} -> {:halt, false}
        {:ok, _} -> {:cont, current}
        _ -> {:halt, false}
      end
    end) != false
  end

  defp open_http(uri) do
    hosts = Application.get_env(:lixi, :http_hosts, [])

    with true <-
           Application.get_env(:lixi, :http_sources) and uri.host in hosts and
             is_nil(uri.userinfo),
         {:ok, {{_, 200, _}, headers, _}} <-
           :httpc.request(
             :head,
             {URI.to_string(uri) |> String.to_charlist(), []},
             http_options(),
             []
           ),
         {length, ""} <- Integer.parse(header(headers, ~c"content-length") || ""),
         true <- length > 0,
         etag when is_binary(etag) <- header(headers, ~c"etag"),
         false <- String.starts_with?(etag, "W/") do
      {:ok,
       %{
         kind: :http,
         identifier: URI.to_string(uri),
         length: length,
         version: etag,
         extension: extension(uri.path || "")
       }}
    else
      _ -> {:error, :http_source_unavailable}
    end
  end

  defp read_source(%{kind: :file} = source, offset, length) do
    with {:ok, stat} <- File.stat(source.identifier, time: :posix),
         true <- {stat.inode, stat.size, stat.mtime} == source.version,
         {:ok, bytes} <- :file.pread(source.file, offset, length),
         true <- byte_size(bytes) == length do
      {:ok, bytes}
    else
      _ -> {:error, :source_changed}
    end
  end

  defp read_source(%{kind: :http} = source, offset, length) do
    headers = [
      {~c"range", String.to_charlist("bytes=#{offset}-#{offset + length - 1}")},
      {~c"if-range", String.to_charlist(source.version)},
      {~c"accept-encoding", ~c"identity"}
    ]

    request = {String.to_charlist(source.identifier), headers}

    with {:ok, ref} <-
           :httpc.request(:get, request, http_options(),
             sync: false,
             stream: {:self, :once},
             body_format: :binary
           ) do
      try do
        receive do
          {:http, {^ref, :stream_start, response_headers, handler}} ->
            expected = "bytes #{offset}-#{offset + length - 1}/#{source.length}"

            if header(response_headers, ~c"content-range") == expected and
                 header(response_headers, ~c"etag") == source.version do
              :httpc.stream_next(handler)
              read_body(ref, handler, length, [], 0)
            else
              {:error, :source_changed}
            end

          {:http, {^ref, _}} ->
            {:error, :range_not_supported}
        after
          5_000 -> {:error, :timeout}
        end
      after
        :httpc.cancel_request(ref)
      end
    end
  end

  defp read_body(ref, handler, length, chunks, size) do
    receive do
      {:http, {^ref, :stream, bytes}} when byte_size(bytes) + size <= length ->
        :httpc.stream_next(handler)
        read_body(ref, handler, length, [bytes | chunks], size + byte_size(bytes))

      {:http, {^ref, :stream_end, _}} when size == length ->
        {:ok, IO.iodata_to_binary(Enum.reverse(chunks))}

      {:http, {^ref, _}} ->
        {:error, :invalid_response}

      {:http, {^ref, _, _}} ->
        {:error, :invalid_response}
    after
      5_000 -> {:error, :timeout}
    end
  end

  defp http_options,
    do: [
      timeout: 5_000,
      connect_timeout: 3_000,
      autoredirect: false,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

  defp header(headers, name) do
    case List.keyfind(headers, name, 0) do
      nil -> nil
      {_, value} -> to_string(value)
    end
  end

  defp extension(path),
    do: path |> Path.extname() |> String.trim_leading(".") |> String.downcase()
end
