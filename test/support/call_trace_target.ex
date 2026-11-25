defmodule Cinder.CallTraceTarget do
  @moduledoc """
  Functions `Cinder.CallTraceTest` traces. Only that test calls them, so it can unload this module
  to show `Cinder.CallTrace.calls/2` loads it.
  """

  @doc "`n` doubled."
  def double(n), do: n * 2

  @doc "Counts down to 0, one recursive call per step."
  def count_down(0), do: :done
  def count_down(n), do: count_down(n - 1)

  @doc "Raises `ArgumentError`."
  def boom, do: raise(ArgumentError, "boom")
end
