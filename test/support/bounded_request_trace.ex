defmodule Cinder.Test.BoundedRequestTrace do
  @moduledoc """
  Traces each call the test process makes into `Cinder.HTTPPolicy.bounded_request/2` or `/3`, so
  a test can read the deadline a client passes.

  `start/0` sets a global trace pattern, so a module that calls it runs `async: false`. Only remote
  calls match, so the default deadline that `/2` passes on to `/3` inside `HTTPPolicy` adds no
  message. A process that traces itself gets no trace messages, so a supervised tracer forwards
  each one to the test; `deliver/1` waits for them.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  @doc "Starts tracing the test process's calls into `bounded_request/2,3` and returns the tracer."
  def start do
    Code.ensure_loaded!(Cinder.HTTPPolicy)
    test = self()
    tracer = start_supervised!({Task, fn -> forward_to(test) end}, id: make_ref())

    for arity <- [2, 3] do
      mfa = {Cinder.HTTPPolicy, :bounded_request, arity}
      assert 1 == :erlang.trace_pattern(mfa, true, [])
      on_exit(fn -> :erlang.trace_pattern(mfa, false, []) end)
    end

    assert 1 == :erlang.trace(test, true, [:call, {:tracer, tracer}])
    tracer
  end

  @doc """
  Returns once every trace message of the calls made so far sits in the test's mailbox:
  `trace_delivered/1` waits until the tracer has them, and the tracer forwards the sync message
  after them.
  """
  def deliver(tracer) do
    ref = :erlang.trace_delivered(self())
    assert_receive {:trace_delivered, _pid, ^ref}, 5_000
    send(tracer, {:traces_forwarded, ref})
    assert_receive {:traces_forwarded, ^ref}, 5_000
  end

  @doc """
  Delivers the traces of the calls made so far, takes them out of the mailbox and returns each
  call's argument list in call order.
  """
  def calls(tracer) do
    deliver(tracer)
    take_calls([])
  end

  defp take_calls(calls) do
    receive do
      {:trace, _pid, :call, {Cinder.HTTPPolicy, :bounded_request, args}} ->
        take_calls([args | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end

  defp forward_to(test) do
    receive do
      message -> send(test, message)
    end

    forward_to(test)
  end
end
