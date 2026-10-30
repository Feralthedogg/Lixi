defmodule Lixi.Track do
  @moduledoc "Lavaplayer version 1–3 track envelopes, including Java modified UTF-8."
  import Bitwise

  def new(info, container) do
    body =
      IO.iodata_to_binary([
        <<3>>,
        utf(info["title"]),
        utf(info["author"]),
        <<info["length"]::signed-64>>,
        utf(info["identifier"]),
        <<if(info["isStream"], do: 1, else: 0)>>,
        nullable(info["uri"]),
        nullable(info["artworkUrl"]),
        nullable(info["isrc"]),
        utf(info["sourceName"]),
        utf(container),
        <<info["position"]::signed-64>>
      ])

    %{
      "encoded" => Base.encode64(<<byte_size(body) ||| 0x40000000::32, body::binary>>),
      "info" => info,
      "pluginInfo" => %{},
      "userData" => %{}
    }
  end

  def decode(encoded) when is_binary(encoded) and byte_size(encoded) <= 131_072 do
    with {:ok, <<header::32, body::binary>>} <- Base.decode64(encoded),
         true <- (header &&& 0x3FFFFFFF) == byte_size(body),
         {version, body} <- version(header, body),
         true <- version in 1..3,
         {:ok, title, body} <- read_utf(body),
         {:ok, author, <<length::signed-64, body::binary>>} <- read_utf(body),
         true <- length >= 0,
         {:ok, identifier, <<stream, body::binary>>} <- read_utf(body),
         true <- stream in [0, 1],
         {:ok, uri, body} <- read_nullable(body, version >= 2),
         {:ok, artwork, body} <- read_nullable(body, version >= 3),
         {:ok, isrc, body} <- read_nullable(body, version >= 3),
         {:ok, source, rest} <- read_utf(body),
         true <- byte_size(rest) >= 8,
         details_size = byte_size(rest) - 8,
         <<_details::binary-size(^details_size), position::signed-64>> <- rest,
         true <- position >= 0 do
      {:ok,
       %{
         "encoded" => encoded,
         "info" => %{
           "identifier" => identifier,
           "isSeekable" => stream == 0,
           "author" => author,
           "length" => length,
           "isStream" => stream == 1,
           "position" => position,
           "title" => title,
           "uri" => uri,
           "artworkUrl" => artwork,
           "isrc" => isrc,
           "sourceName" => source
         },
         "pluginInfo" => %{},
         "userData" => %{}
       }}
    else
      _ -> {:error, "Invalid encoded track"}
    end
  end

  def decode(_), do: {:error, "Invalid encoded track"}

  defp version(header, <<version, rest::binary>>) when (header &&& 0x40000000) != 0,
    do: {version, rest}

  defp version(_, body), do: {1, body}
  defp nullable(nil), do: <<0>>
  defp nullable(value), do: [<<1>>, utf(value)]
  defp read_nullable(body, false), do: {:ok, nil, body}
  defp read_nullable(<<0, rest::binary>>, true), do: {:ok, nil, rest}
  defp read_nullable(<<1, rest::binary>>, true), do: read_utf(rest)
  defp read_nullable(_, _), do: :error

  defp utf(value) do
    units = :unicode.characters_to_binary(value, :utf8, {:utf16, :big})

    data =
      for <<unit::16 <- units>>, into: <<>> do
        cond do
          unit in 1..127 -> <<unit>>
          unit < 2048 -> <<0xC0 ||| unit >>> 6, 0x80 ||| (unit &&& 63)>>
          true -> <<0xE0 ||| unit >>> 12, 0x80 ||| (unit >>> 6 &&& 63), 0x80 ||| (unit &&& 63)>>
        end
      end

    if byte_size(data) > 65_535, do: raise(ArgumentError, "Track text too long")
    <<byte_size(data)::16, data::binary>>
  end

  defp read_utf(<<length::16, encoded::binary-size(length), rest::binary>>) do
    with {:ok, units} <- units(encoded, []),
         text when is_binary(text) <-
           :unicode.characters_to_binary(Enum.reverse(units), {:utf16, :big}, :utf8) do
      {:ok, text, rest}
    else
      _ -> :error
    end
  end

  defp read_utf(_), do: :error
  defp units(<<>>, acc), do: {:ok, acc}
  defp units(<<a, rest::binary>>, acc) when a in 1..127, do: units(rest, [<<a::16>> | acc])

  defp units(<<a, b, rest::binary>>, acc) when a in 0xC0..0xDF and b in 0x80..0xBF,
    do: units(rest, [<<(a &&& 31) <<< 6 ||| (b &&& 63)::16>> | acc])

  defp units(<<a, b, c, rest::binary>>, acc)
       when a in 0xE0..0xEF and b in 0x80..0xBF and c in 0x80..0xBF,
       do: units(rest, [<<(a &&& 15) <<< 12 ||| (b &&& 63) <<< 6 ||| (c &&& 63)::16>> | acc])

  defp units(_, _), do: :error
end
