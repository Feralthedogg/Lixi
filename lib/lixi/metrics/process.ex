defmodule Lixi.Metrics.Process do
  @moduledoc false

  # OS sampling stays off the playback clock. RSS includes
  # shared pages in each process; it is not a unique physical-memory estimate.
  def units do
    if :os.type() == {:unix, :linux} do
      {ticks, 0} = System.cmd("getconf", ["CLK_TCK"])
      {pages, 0} = System.cmd("getconf", ["PAGESIZE"])

      {:linux, ticks |> String.trim() |> String.to_integer(),
       pages |> String.trim() |> String.to_integer()}
    else
      :ps
    end
  rescue
    _ -> :ps
  end

  def sample(pids, {:linux, ticks, pages}) do
    Enum.reduce(pids, %{}, fn pid, acc ->
      with {:ok, text} <- File.read("/proc/#{pid}/stat"),
           {:ok, sample} <- parse_proc(text, ticks, pages) do
        Map.put(acc, pid, sample)
      else
        _ -> acc
      end
    end)
  end

  def sample(pids, :ps) do
    pids
    |> Enum.chunk_every(256)
    |> Enum.reduce(%{}, fn batch, acc ->
      {output, _} =
        System.cmd("ps", ["-o", "pid=,rss=,time=,lstart=", "-p", Enum.join(batch, ",")],
          env: [{"LC_ALL", "C"}]
        )

      Map.merge(acc, parse(output))
    end)
  rescue
    _ -> %{}
  end

  def parse_proc(text, ticks, pages) do
    # comm can contain spaces and parentheses; fields follow its final ') '.
    case Regex.run(~r/^\d+ \(.*\) (.*)$/s, text, capture: :all_but_first) do
      [tail] ->
        fields = String.split(tail)

        {:ok,
         %{
           cpu_ms:
             div(
               (String.to_integer(Enum.at(fields, 11)) + String.to_integer(Enum.at(fields, 12))) *
                 1000,
               ticks
             ),
           identity: Enum.at(fields, 19),
           rss: max(String.to_integer(Enum.at(fields, 21)), 0) * pages
         }}

      _ ->
        {:error, :invalid_stat}
    end
  rescue
    _ -> {:error, :invalid_stat}
  end

  def parse(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line) do
        [pid, rss, cpu | start] when length(start) == 5 ->
          Map.put(acc, String.to_integer(pid), %{
            rss: String.to_integer(rss) * 1024,
            cpu_ms: cpu_ms(cpu),
            identity: Enum.join(start, " ")
          })

        _ ->
          acc
      end
    end)
  end

  defp cpu_ms(value) do
    {days, clock} =
      case String.split(value, "-") do
        [clock] -> {0, clock}
        [days, clock] -> {String.to_integer(days), clock}
      end

    seconds =
      clock
      |> String.split(":")
      |> Enum.reduce(0.0, fn part, total ->
        total * 60 + String.to_float(if String.contains?(part, "."), do: part, else: part <> ".0")
      end)

    round((days * 86_400 + seconds) * 1000)
  end

  def cpu_delta(current, previous) do
    Enum.reduce(current, 0, fn {pid, item}, total ->
      case previous[pid] do
        %{identity: identity, cpu_ms: before} when identity == item.identity ->
          total + max(item.cpu_ms - before, 0)

        _ ->
          total
      end
    end)
  end
end
