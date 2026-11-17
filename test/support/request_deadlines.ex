defmodule Cinder.Test.RequestDeadlines do
  @moduledoc """
  Reads the total deadline that `Cinder.HTTPPolicy.bounded_request/2,3` gave each request the
  calling process made, from the `deadline_ms` of its `[:cinder, :http, :request_task]` events.

  The event carries the same value the request task and its await run under, so a test reads the
  deadline the request got, not the arguments a client passed. The handler sees every process's
  events, so only the calling process's are kept, and a module that uses this can run
  `async: true`.
  """

  @doc """
  Runs `fun` and returns `{result, requests}`: one `{path, deadline_ms}` per request the calling
  process made, in call order.
  """
  def capture(fun) do
    caller = self()
    {result, events} = Cinder.TelemetryHelpers.capture([:cinder, :http, :request_task], fun)

    requests =
      for {_measurements, %{caller: ^caller} = metadata} <- events,
          do: {Map.fetch!(metadata, :path), Map.fetch!(metadata, :deadline_ms)}

    {result, requests}
  end
end
