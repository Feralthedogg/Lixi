defmodule Lixi.Sources do
  def load(identifier) do
    if is_binary(identifier) and byte_size(identifier) in 1..8192 do
      case Lixi.Plugins.load(identifier) do
        :unhandled -> load_builtin(identifier)
        {:ok, result} -> result
        {:error, reason} -> load_error(reason)
      end
    else
      load_error(:invalid_identifier)
    end
  end

  def resolve(identifier) do
    case load(identifier) do
      %{"loadType" => "track", "data" => track} -> {:ok, track}
      %{"loadType" => "empty"} -> {:error, :unsupported_source}
      %{"loadType" => "error", "data" => error} -> {:error, error["cause"]}
      _ -> {:error, :not_a_single_track}
    end
  end

  def load_builtin(identifier) do
    case resolve_builtin(identifier) do
      {:ok, track} ->
        %{"loadType" => "track", "data" => track}

      {:error, :unsupported_source} ->
        %{"loadType" => "empty", "data" => nil}

      {:error, reason} ->
        %{
          "loadType" => "error",
          "data" => %{
            "message" => "Could not load track",
            "severity" => "common",
            "cause" => inspect(reason),
            "causeStackTrace" => ""
          }
        }
    end
  end

  defp load_error(reason),
    do: %{
      "loadType" => "error",
      "data" => %{
        "message" => "Could not load track",
        "severity" => "fault",
        "cause" => inspect(reason),
        "causeStackTrace" => ""
      }
    }

  def resolve_builtin(identifier)
      when is_binary(identifier) and byte_size(identifier) in 1..8192 do
    if String.starts_with?(identifier, ["ytsearch:", "ytmsearch:", "scsearch:"]) do
      {:error, :unsupported_source}
    else
      case Lixi.Audio.Worker.start(self(), identifier, 0) do
        {:ok, worker} ->
          try do
            receive do
              {:audio, ^worker, 0, {:ready, metadata}} ->
                uri = URI.parse(identifier)
                source = if uri.scheme in ["http", "https"], do: "http", else: "local"
                name = Path.basename(uri.path || identifier) |> String.slice(0, 512)

                info = %{
                  "identifier" => identifier,
                  "isSeekable" => true,
                  "author" => "Unknown artist",
                  "length" => metadata["length"],
                  "isStream" => false,
                  "position" => 0,
                  "title" => name,
                  "uri" => identifier,
                  "artworkUrl" => nil,
                  "isrc" => nil,
                  "sourceName" => source
                }

                {:ok,
                 Lixi.Track.new(
                   info,
                   (uri.path || identifier)
                   |> Path.extname()
                   |> String.trim_leading(".")
                   |> String.downcase()
                 )}

              {:audio, ^worker, 0, {:error, reason}} ->
                {:error, reason}
            after
              10_000 -> {:error, :load_timeout}
            end
          after
            Lixi.Audio.Worker.stop(worker)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def resolve_builtin(_), do: {:error, :invalid_identifier}
end
