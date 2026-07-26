defmodule Cinder.TelemetryHelpers do
  @moduledoc """
  Shared `:telemetry.attach/2`/`detach/1` idiom for asserting a domain event fired — the same
  idiom `Cinder.CatalogRefreshTest`'s query-count helper uses, generalized and made race-free for
  reuse across the domain-telemetry tests (transition/park/poller-tick/http).

  `:telemetry` handlers run synchronously in the *emitting* process, not the attaching one, so
  the handler here closes over the calling test process's pid. Filtering the drained mailbox by
  the same `ref` used as the attach id (rather than by event metadata) means two concurrent
  `capture/2` calls on the same event name can never see each other's messages, even under
  `async: true`.
  """

  @doc """
  Runs `fun`, capturing every `event_name` emitted during the call. Returns
  `{fun_result, events}`, where `events` is a list of `{measurements, metadata}` pairs in
  emission order. The handler is always detached before returning, including on a raise, so a
  leaked handler can't inspect a later, unrelated test's events.
  """
  def capture(event_name, fun) do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      ref,
      event_name,
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_captured, ref, measurements, metadata})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(ref)}
    after
      :telemetry.detach(ref)
    end
  end

  defp drain(ref) do
    receive do
      {:telemetry_captured, ^ref, measurements, metadata} ->
        [{measurements, metadata} | drain(ref)]
    after
      0 -> []
    end
  end
end
