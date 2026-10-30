Code.require_file("../scripts/validation/watch.exs", __DIR__)

defmodule Lixi.ValidationTest do
  use ExUnit.Case, async: true
  alias Lixi.Validation.Watch

  test "initial progress cannot hide a later disconnect or an unrecovered reconnect" do
    watch = Watch.new(0) |> Watch.delivered()
    assert Watch.passed?(watch)
    watch = Watch.sample(watch, false, 100, 1000)
    refute Watch.passed?(watch)
    refute Watch.expired?(watch, 30_999)
    assert Watch.expired?(watch, 31_000)
    watch = Watch.new(0) |> Watch.delivered() |> Watch.reconnect(1000)
    watch = Watch.sample(watch, true, 100, 2000)
    refute Watch.passed?(watch)
    assert Watch.expired?(watch, 31_000)
    watch = Watch.sample(watch, true, 120, 3000)
    assert Watch.passed?(watch)
    assert Watch.summary(watch).recovered == 1
  end

  test "media acquisition does not hide loss of connectivity or mark an idle gap stalled" do
    watch = Watch.new(0) |> Watch.delivered()
    watch = Watch.sample(watch, true, 100, 1000, false)
    watch = Watch.sample(watch, true, 100, 6000, false)
    assert watch.stalled == 0
    watch = Watch.sample(watch, false, 100, 7000, false)
    assert Watch.expired?(watch, 37_000)
    refute Watch.passed?(watch)
  end
end
