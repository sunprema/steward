defmodule Steward.Coordinator.Plane.Limiter do
  @moduledoc """
  The per-data-plane heartbeat token bucket (doc 07 §5.3, "Storms"): sized at 3×
  the data plane's steady-state rate, `non_terminal_branches / 30 s`, with a
  floor of 100 per second. After a data-plane restart every branch heartbeats at
  once; over budget a heartbeat is dropped, which is safe because the data plane
  keeps its last known state and no transition depends on a single heartbeat.

  Pure and clock-injected so it tests without sleeping. One limiter lives in the
  process that reads a stream, and there is one stream per identity (doc 10 §5),
  so no sharing is needed.
  """
  defstruct [:rate, :burst, :tokens, :at]

  @floor_per_s 100
  @period_s 30
  @burst_s 2

  @type t :: %__MODULE__{rate: float(), burst: float(), tokens: float(), at: integer()}

  @doc "Tokens per second for a data plane with `non_terminal` branches: 3 × n / 30 s, at least 100."
  def rate_for(non_terminal) when is_integer(non_terminal) and non_terminal >= 0,
    do: max(@floor_per_s, 3 * non_terminal / @period_s)

  @doc "A full bucket at `rate` per second; it holds two seconds of burst. `now` is monotonic milliseconds."
  def new(rate, now) do
    burst = rate * @burst_s
    %__MODULE__{rate: rate / 1, burst: burst, tokens: burst, at: now}
  end

  @doc "Changes the rate (the branch count moved), keeping the tokens it has, capped to the new burst."
  def retune(%__MODULE__{} = l, rate, now) do
    l = refill(l, now)
    burst = rate * @burst_s
    %{l | rate: rate / 1, burst: burst, tokens: min(l.tokens, burst)}
  end

  @doc "Takes one token: `{:ok, limiter}` or `{:limited, limiter}`."
  def take(%__MODULE__{} = l, now) do
    l = refill(l, now)

    if l.tokens >= 1,
      do: {:ok, %{l | tokens: l.tokens - 1}},
      else: {:limited, l}
  end

  @doc "The back-off a rejected data plane is told to wait: uniform 0–30 s (doc 07 §5.3)."
  def retry_after_ms, do: :rand.uniform(30_000) - 1

  defp refill(%__MODULE__{at: at} = l, now) when now > at do
    %{l | tokens: min(l.burst, l.tokens + (now - at) / 1000 * l.rate), at: now}
  end

  defp refill(l, _now), do: l
end
