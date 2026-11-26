defmodule Cinder.CallTraceTest do
  # Unloads `Cinder.CallTraceTarget`, which only this module calls.
  use ExUnit.Case, async: false

  alias Cinder.{CallTrace, CallTraceTarget}

  test "records each call's arguments and return, in call order" do
    assert {6, calls} =
             CallTrace.calls({CallTraceTarget, :double, 1}, fn ->
               CallTraceTarget.double(1) + CallTraceTarget.double(2)
             end)

    assert calls == [%{args: [1], result: {:return, 2}}, %{args: [2], result: {:return, 4}}]
  end

  test "pairs nested calls of a recursive function with their own returns" do
    assert {:done, calls} =
             CallTrace.calls({CallTraceTarget, :count_down, 1}, fn ->
               CallTraceTarget.count_down(2)
             end)

    assert Enum.map(calls, & &1.args) == [[2], [1], [0]]
    assert Enum.all?(calls, &(&1.result == {:return, :done}))
  end

  test "records a call that raised as its exception" do
    assert {:rescued, [%{args: [], result: {:exception, {:error, %ArgumentError{}}}}]} =
             CallTrace.calls({CallTraceTarget, :boom, 0}, fn ->
               try do
                 CallTraceTarget.boom()
               rescue
                 ArgumentError -> :rescued
               end
             end)
  end

  test "leaves out the calls of another function a pattern set elsewhere matches" do
    other = {CallTraceTarget, :count_down, 1}
    # A trace pattern matches only loaded functions, and this test can run before any other
    # test loads `CallTraceTarget`.
    Code.ensure_loaded!(CallTraceTarget)
    assert :erlang.trace_pattern(other, [{:_, [], [{:return_trace}]}], [:local]) == 1
    on_exit(fn -> :erlang.trace_pattern(other, false, [:local]) end)

    assert {4, [%{args: [2], result: {:return, 4}}]} =
             CallTrace.calls({CallTraceTarget, :double, 1}, fn ->
               CallTraceTarget.count_down(1)
               CallTraceTarget.double(2)
             end)
  end

  test "loads a module that is not loaded yet" do
    :code.purge(CallTraceTarget)
    :code.delete(CallTraceTarget)
    :code.purge(CallTraceTarget)
    refute :code.is_loaded(CallTraceTarget)

    assert {2, [%{args: [1]}]} =
             CallTrace.calls({CallTraceTarget, :double, 1}, fn -> CallTraceTarget.double(1) end)
  end

  test "fails on a function that does not exist" do
    assert_raise ExUnit.AssertionError, ~r/matches no function/, fn ->
      CallTrace.calls({CallTraceTarget, :double, 2}, fn -> :ok end)
    end
  end

  test "leaves no trace pattern behind" do
    CallTrace.calls({CallTraceTarget, :double, 1}, fn -> :ok end)
    assert :erlang.trace_info({CallTraceTarget, :double, 1}, :traced) == {:traced, false}
  end
end
