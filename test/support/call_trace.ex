defmodule Cinder.CallTrace do
  @moduledoc """
  The calls the test process, or the process the `pid:` option names, makes to one function while
  `fun` runs, each with its arguments and its result, through `:erlang.trace/3`.

  `calls/2` handles three traps of a hand-written call trace:

  - A process receives no trace messages for its own calls, so a tracer process under the test
    supervisor collects them.
  - A trace pattern on a module that is not loaded yet matches no function, so `calls/2` loads
    the module first and fails when the pattern still matches none.
  - The runtime can still be delivering trace messages when `fun` returns, so `calls/2` waits for
    `:erlang.trace_delivered/1` before it reads them.

  Only the traced process's calls are traced, but a trace pattern is global to the node, and
  `calls/2` turns it off when `fun` returns. Two tests that trace the same function at the same
  time therefore run in modules with `async: false`.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 2]

  @typedoc "One call: its arguments and `{:return, value}` or `{:exception, {class, reason}}`."
  @type call :: %{args: [term()], result: {:return, term()} | {:exception, {atom(), term()}}}

  @doc """
  Runs `fun` in the test process and returns `{fun's result, calls}`: every call to `mfa` the
  traced process made while `fun` ran, in call order. The traced process is the test process, or
  the one `opts`' `pid:` names, such as a LiveView's `view.pid`: for that one, `fun` returns only
  once the calls it waits for have run, as a `render_submit/3` returns after the view's reply,
  and that process must still live then, or turning its trace off raises.
  Fails the test when `mfa` names no function. A call to another function that a
  trace pattern set elsewhere matches is left out.
  """
  @spec calls(mfa(), (-> result), keyword()) :: {result, [call()]} when result: term()
  def calls({module, _name, _arity} = mfa, fun, opts \\ []) do
    test_pid = self()
    traced = Keyword.get(opts, :pid, test_pid)
    tracer = start_supervised!({Task, fn -> collect(test_pid, mfa, []) end}, id: make_ref())

    Code.ensure_loaded!(module)

    assert :erlang.trace_pattern(mfa, [{:_, [], [{:exception_trace}]}], [:local]) == 1,
           "#{inspect(mfa)} matches no function"

    :erlang.trace(traced, true, [:call, {:tracer, tracer}])

    result =
      try do
        fun.()
      after
        :erlang.trace(traced, false, [:call])
        :erlang.trace_pattern(mfa, false, [:local])
      end

    ref = :erlang.trace_delivered(traced)
    assert_receive {:trace_delivered, _pid, ^ref}
    send(tracer, :done)
    assert_receive {:call_trace, ^tracer, messages}
    {result, pair(messages)}
  end

  # Keeps only the messages of `mfa`: the test process carries the call flag, so a pattern another
  # test set on a function it calls sends messages here too.
  defp collect(test_pid, {module, name, arity} = mfa, messages) do
    receive do
      {:trace, _pid, :call, {^module, ^name, args}} = message when length(args) == arity ->
        collect(test_pid, mfa, [message | messages])

      {:trace, _pid, kind, ^mfa, _value} = message when kind in [:return_from, :exception_from] ->
        collect(test_pid, mfa, [message | messages])

      {:trace, _pid, _kind, _other} ->
        collect(test_pid, mfa, messages)

      {:trace, _pid, _kind, _other, _value} ->
        collect(test_pid, mfa, messages)

      :done ->
        send(test_pid, {:call_trace, self(), Enum.reverse(messages)})
    end
  end

  # Pairs each call with the return or exception that ends it. Calls can nest (a recursive
  # function), so the open calls form a stack.
  defp pair(messages) do
    {done, [], _index} =
      Enum.reduce(messages, {[], [], 0}, fn
        {:trace, _pid, :call, {_m, _f, args}}, {done, open, index} ->
          {done, [{index, args} | open], index + 1}

        {:trace, _pid, :return_from, _mfa, value}, {done, [{i, args} | open], index} ->
          {[{i, %{args: args, result: {:return, value}}} | done], open, index}

        {:trace, _pid, :exception_from, _mfa, value}, {done, [{i, args} | open], index} ->
          {[{i, %{args: args, result: {:exception, value}}} | done], open, index}
      end)

    done |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
  end
end
