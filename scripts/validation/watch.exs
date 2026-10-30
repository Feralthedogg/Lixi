defmodule Lixi.Validation.Watch do
  @moduledoc false
  def new(now) do
    %{
      awaiting: true,
      deadline: now + 30_000,
      connected: false,
      last_position: nil,
      progress: 0,
      stalled: 0,
      reconnects: 0,
      recovered: 0,
      connected_samples: 0,
      disconnected_samples: 0
    }
  end

  def reconnect(watch, now),
    do: %{
      watch
      | awaiting: true,
        deadline: now + 30_000,
        connected: false,
        last_position: nil,
        reconnects: watch.reconnects + 1
    }

  def delivered(watch),
    do: %{
      watch
      | awaiting: false,
        connected: true,
        recovered: watch.reconnects,
        progress: watch.progress + 1
    }

  def sample(watch, connected, position, now, expect_audio \\ true) do
    advancing =
      connected and is_integer(position) and is_integer(watch.last_position) and
        position != watch.last_position

    stalled =
      expect_audio and connected and watch.last_position == position and is_integer(position)

    watch = %{
      watch
      | connected: connected,
        last_position: if(expect_audio, do: position, else: nil),
        connected_samples: watch.connected_samples + if(connected, do: 1, else: 0),
        disconnected_samples: watch.disconnected_samples + if(connected, do: 0, else: 1),
        stalled: watch.stalled + if(stalled, do: 1, else: 0)
    }

    cond do
      advancing -> delivered(watch)
      not connected and not watch.awaiting -> %{watch | awaiting: true, deadline: now + 30_000}
      true -> watch
    end
  end

  def expired?(watch, now), do: watch.awaiting and now >= watch.deadline

  def passed?(watch),
    do:
      watch.connected and not watch.awaiting and watch.progress > 0 and
        watch.recovered == watch.reconnects and watch.stalled == 0

  def summary(watch),
    do:
      Map.take(watch, [
        :progress,
        :stalled,
        :connected_samples,
        :disconnected_samples,
        :reconnects,
        :recovered
      ])
end
