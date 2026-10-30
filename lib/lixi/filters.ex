defmodule Lixi.Filters do
  @moduledoc "Validates only filters implemented by the native engine; /info advertises this set."
  @supported [
    "timescale",
    "vibrato",
    "volume",
    "equalizer",
    "channelMix",
    "lowPass",
    "tremolo",
    "rotation",
    "karaoke",
    "distortion"
  ]
  def supported, do: @supported

  @defaults %{
    "karaoke" => %{
      "level" => 1.0,
      "monoLevel" => 1.0,
      "filterBand" => 220.0,
      "filterWidth" => 100.0
    },
    "timescale" => %{"speed" => 1.0, "pitch" => 1.0, "rate" => 1.0},
    "tremolo" => %{"frequency" => 2.0, "depth" => 0.5},
    "vibrato" => %{"frequency" => 2.0, "depth" => 0.5},
    "rotation" => %{"rotationHz" => 0.0},
    "distortion" => %{
      "sinOffset" => 0.0,
      "sinScale" => 1.0,
      "cosOffset" => 0.0,
      "cosScale" => 1.0,
      "tanOffset" => 0.0,
      "tanScale" => 1.0,
      "offset" => 0.0,
      "scale" => 1.0
    },
    "channelMix" => %{
      "leftToLeft" => 1.0,
      "leftToRight" => 0.0,
      "rightToLeft" => 0.0,
      "rightToRight" => 1.0
    },
    "lowPass" => %{"smoothing" => 20.0}
  }
  @nullable ~w(karaoke timescale tremolo vibrato rotation distortion channelMix lowPass)

  def normalize(filters) do
    Enum.reduce(filters, %{}, fn {name, value}, result ->
      value =
        cond do
          name == "equalizer" -> Enum.map(value, &Map.put_new(&1, "gain", 1.0))
          is_map(value) and Map.has_key?(@defaults, name) -> Map.merge(@defaults[name], value)
          true -> value
        end

      if is_nil(value) or neutral?(name, value), do: result, else: Map.put(result, name, value)
    end)
  end

  defp neutral?("volume", value), do: value == 1.0
  defp neutral?("pluginFilters", value), do: value == %{}
  defp neutral?("equalizer", bands), do: Enum.all?(bands, &(&1["gain"] == 0))

  defp neutral?(name, value) when name in ~w(timescale channelMix rotation distortion),
    do: value == @defaults[name]

  defp neutral?(name, value) when name in ~w(tremolo vibrato), do: value["depth"] == 0
  defp neutral?("lowPass", value), do: value["smoothing"] <= 1
  defp neutral?(_, _), do: false

  def validate(filters) when is_map(filters) do
    Enum.reduce_while(filters, :ok, fn {name, value}, :ok ->
      if valid?(name, value),
        do: {:cont, :ok},
        else: {:halt, {:error, "Unsupported or invalid filter: #{name}"}}
    end)
  end

  def validate(_), do: {:error, "filters must be an object"}
  defp valid?(name, nil) when name in @nullable, do: true
  defp valid?("volume", n), do: is_number(n) and n >= 0 and n <= 5
  defp valid?("pluginFilters", value), do: value == %{}

  defp valid?("equalizer", bands) when is_list(bands) and length(bands) <= 15 do
    Enum.all?(bands, fn
      %{"band" => b} = band ->
        g = Map.get(band, "gain", 1.0)
        is_integer(b) and b in 0..14 and is_number(g) and g >= -0.25 and g <= 1.0

      _ ->
        false
    end)
  end

  defp valid?(name, value) when is_map(value) do
    case name do
      "timescale" ->
        known?(value, ~w(speed pitch rate)) and fields?(value, ~w(speed pitch rate), 0.25, 4)

      "vibrato" ->
        known?(value, ~w(frequency depth)) and fields?(value, ["frequency"], 0.01, 14) and
          fields?(value, ["depth"], 0, 1)

      "channelMix" ->
        fields?(value, ~w(leftToLeft leftToRight rightToLeft rightToRight), 0, 1)

      "lowPass" ->
        fields?(value, ["smoothing"], 1, 1000)

      "tremolo" ->
        fields?(value, ["frequency"], 0.01, 1000) and fields?(value, ["depth"], 0, 1) and
          known?(value, ~w(frequency depth))

      "rotation" ->
        fields?(value, ["rotationHz"], -1000, 1000)

      "karaoke" ->
        fields?(value, ~w(level monoLevel), 0, 1) and
          fields?(value, ~w(filterBand filterWidth), 0, 24000) and
          known?(value, ~w(level monoLevel filterBand filterWidth))

      "distortion" ->
        fields?(
          value,
          ~w(sinOffset sinScale cosOffset cosScale tanOffset tanScale offset scale),
          -1000,
          1000
        )

      _ ->
        false
    end
  end

  defp valid?(_, _), do: false
  defp known?(map, fields), do: Enum.all?(Map.keys(map), &(&1 in fields))

  defp fields?(map, fields, min, max) do
    Enum.all?(fields, fn key ->
      not Map.has_key?(map, key) or (is_number(map[key]) and map[key] >= min and map[key] <= max)
    end)
  end
end
