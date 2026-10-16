defmodule Steward.Coordinator.Plane.LimiterTest do
  @moduledoc "The heartbeat token bucket of doc 07 §5.3 (\"Storms\"). Pure; the clock is passed in."
  use ExUnit.Case, async: true

  alias Steward.Coordinator.Plane.Limiter

  test "the rate is 3× the steady state (branches / 30 s), at least 100 per second" do
    assert Limiter.rate_for(0) == 100
    assert Limiter.rate_for(1_000) == 100
    assert Limiter.rate_for(1_000_000) == 100_000.0
    assert Limiter.rate_for(2_000_000) == 200_000.0
    assert Limiter.rate_for(1_500) == 150.0
  end

  test "a new bucket holds two seconds of burst, then limits" do
    l = Limiter.new(10, 0)
    {l, taken} = drain(l, 0)
    assert taken == 20
    assert {:limited, _} = Limiter.take(l, 0)
  end

  test "tokens come back at the rate, no further than the burst" do
    l = Limiter.new(10, 0)
    {l, _} = drain(l, 0)

    # 500 ms → 5 tokens
    {l, taken} = drain(l, 500)
    assert taken == 5

    # A long idle refills to the burst and no more.
    {_, taken} = drain(l, 600_000)
    assert taken == 20
  end

  test "a clock that does not move forward adds nothing" do
    l = Limiter.new(10, 1_000)
    {l, _} = drain(l, 1_000)
    assert {:limited, _} = Limiter.take(l, 500)
  end

  test "retuning keeps the tokens it has, capped to the new burst" do
    l = Limiter.new(100, 0)
    l = Limiter.retune(l, 10, 0)
    assert l.rate == 10.0
    assert l.tokens == 20.0

    {l, _} = drain(l, 0)
    l = Limiter.retune(l, 1_000, 0)
    assert l.tokens == 0.0
    assert {:ok, _} = Limiter.take(l, 1)
  end

  test "the back-off a limited data plane is told is within 0–30 s" do
    for _ <- 1..200, do: assert(Limiter.retry_after_ms() in 0..29_999)
  end

  defp drain(l, now, taken \\ 0) do
    case Limiter.take(l, now) do
      {:ok, l} -> drain(l, now, taken + 1)
      {:limited, l} -> {l, taken}
    end
  end
end
