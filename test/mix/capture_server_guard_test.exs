defmodule Cinder.CaptureServerGuardTest do
  # The guard `test/test_helper.exs` installs against the removal of `ExUnit.CaptureServer`'s log
  # handler (#1716). `async: false`: the tests add and remove `:logger` handlers, which every
  # process of the VM shares, and two of them need CaptureServer with no other test's capture
  # open. The first test removes the real handler on purpose, so it prints
  # `Logger - error: {removed_failing_handler,'Elixir.ExUnit.CaptureServer'}` on every run.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  require Logger

  alias Cinder.{CallTrace, CaptureServerGuard}

  defmodule SlowFormatter do
    # Holds the event whose message is the one its config names until the test releases it,
    # past the 5000 ms that `ExUnit.CaptureServer.log/2` waits, and formats every other event at
    # once, so a log call from elsewhere in that window is not held too.
    def format(%{msg: {:string, message}}, {test_pid, ref, message}) do
      send(test_pid, {:formatting, ref, self()})

      receive do
        {:release, ^ref} -> "held\n"
      after
        60_000 -> "held\n"
      end
    end

    def format(event, _config) do
      {formatter, config} = Logger.Formatter.new()
      formatter.format(event, config)
    end
  end

  defmodule NoopHandler do
    # The module of the handlers the stand-in tests add: it drops every event.
    def log(_event, _config), do: :ok
  end

  @server ExUnit.CaptureServer

  setup do
    assert eventually(fn -> open_captures() == 0 end),
           "a log capture is still open in ExUnit.CaptureServer before the test"

    before = logger_state()

    on_exit(fn ->
      assert eventually(fn -> open_captures() == 0 and logger_state() == before end),
             "the test left :logger or ExUnit.CaptureServer changed: " <>
               inspect({open_captures(), logger_state(), before})
    end)
  end

  test "a removal while a capture stays open: the guard adds the handler back inside " <>
         "CaptureServer, the next capture_log captures, and one line names the log call" do
    test_pid = self()
    io = swap_guard_device()

    holder =
      Task.async(fn ->
        capture_log(fn ->
          send(test_pid, :held)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :held
    ref = make_ref()
    message = "held past the wait #{inspect(ref)}"

    {{slow_line, line}, adds} =
      CallTrace.calls(
        {:logger, :add_handler, 3},
        fn ->
          slow_line = __ENV__.line + 3

          capture_log([formatter: {SlowFormatter, {test_pid, ref, message}}], fn ->
            Logger.error(message)
          end)

          assert_received {:formatting, ^ref, formatter}
          send(formatter, {:release, ref})
          # Falls through after 10 s. Without the guard the test then fails on the read below; a
          # guard that adds the handler from its own process fails the `adds` assert instead.
          {slow_line, wait_for_line(io)}
        end,
        pid: Process.whereis(@server)
      )

    assert capture_log(fn -> Logger.error("captured after the removal") end) =~
             "captured after the removal"

    send(holder.pid, :release)
    Task.await(holder)

    assert adds == [%{args: [@server, @server, %{}], result: {:return, :ok}}]
    assert [_one] = String.split(line, "\n", trim: true)
    assert String.ends_with?(line, ".\n")

    assert line =~
             "mix test: :logger removed the log handler ExUnit.CaptureServer (module " <>
               "ExUnit.CaptureServer) after it failed on :error event from #{inspect(test_pid)} " <>
               "at Cinder.CaptureServerGuardTest.\"test a removal while a capture stays open"

    assert line =~
             ", #{__ENV__.file}, line #{slow_line}, with reason {:exit, {:timeout, {Task, :await_many,"

    assert line =~
             ~r/The guard added it back inside ExUnit.CaptureServer, which held [12] open log captures\. File a needs-triage issue that quotes this line \(#1716\)\.\n\z/
  end

  test "a removal report with no capture open adds nothing, and the next capture_log captures " <>
         "on the same CaptureServer" do
    on_exit(&remove_stray_capture_handler/0)
    pid = Process.whereis(@server)
    config = %{server: @server, handler_id: @server, handler_module: @server}

    assert run_guard(report(@server), config) =~
             "The guard added nothing: ExUnit.CaptureServer held no open log capture, and it " <>
               "adds the handler itself when the next one opens. File a needs-triage issue"

    assert capture_log(fn -> Logger.error("captured with no handler added") end) =~
             "captured with no handler added"

    assert Process.whereis(@server) == pid
  end

  test "install/0 adds the guard at level :all, writing to the :standard_error pid of install " <>
         "time, and turns on logger_backend's debug reports" do
    assert {:ok, %{module: CaptureServerGuard, level: :all, config: config}} =
             :logger.get_handler_config(CaptureServerGuard)

    assert %{device: device, server: @server, handler_id: @server, handler_module: @server} =
             config

    assert map_size(config) == 4
    assert is_pid(device)
    assert device == Process.whereis(:standard_error)
    capture_io(:stderr, fn -> send(self(), {:stderr, Process.whereis(:standard_error)}) end)
    assert_received {:stderr, captured}
    refute captured == device
    assert :logger.get_module_level(:logger_backend) == [logger_backend: :debug]
  end

  test "install/1 raises on no :standard_error pid before it changes :logger" do
    # test/test_helper.exs already set the level install/1 sets, which would hide a change.
    :ok = :logger.unset_module_level(:logger_backend)
    on_exit(fn -> :logger.set_module_level(:logger_backend, :debug) end)
    before = {:logger.get_module_level(), :logger.get_handler_ids()}

    assert_raise RuntimeError, "no :standard_error process to write to", fn ->
      CaptureServerGuard.install(nil)
    end

    assert {:logger.get_module_level(), :logger.get_handler_ids()} == before
  end

  describe "against a stand-in server" do
    setup do
      id = :"cinder_capture_server_guard_test_#{System.unique_integer([:positive])}"
      on_exit(fn -> :logger.remove_handler(id) end)
      %{id: id}
    end

    test "with two open captures, adds the handler and prints the whole line", %{id: id} do
      state = %{log_captures: %{make_ref() => true, make_ref() => true}, devices: %{}}
      server = start_supervised!({Agent, fn -> state end})

      assert run_guard(report(id), config(server, id)) ==
               "mix test: :logger removed the log handler #{inspect(id)} (module " <>
                 "Cinder.CaptureServerGuardTest.NoopHandler) after it failed on :error event " <>
                 "from #{inspect(self())} at Foo.bar/2, test/foo_test.exs, line 7, with reason " <>
                 "{:exit, {:timeout, {Task, :await_many, [[], 5000]}}, []}. The guard added it " <>
                 "back inside #{inspect(server)}, which held 2 open log captures. File a " <>
                 "needs-triage issue that quotes this line (#1716).\n"

      assert {:ok, %{module: NoopHandler, level: :all}} = :logger.get_handler_config(id)
      assert Agent.get(server, & &1) == state
    end

    test "with the handler already back, prints what add_handler returned", %{id: id} do
      :ok = :logger.add_handler(id, NoopHandler, %{})
      server = start_supervised!({Agent, fn -> %{log_captures: %{make_ref() => true}} end})

      assert run_guard(report(id), config(server, id)) =~
               "With 1 open log captures, :logger.add_handler/3 inside #{inspect(server)} " <>
                 "returned {:error, {:already_exist, #{inspect(id)}}}. File a needs-triage"
    end

    test "with no open capture, adds nothing", %{id: id} do
      server = start_supervised!({Agent, fn -> %{log_captures: %{}} end})

      assert run_guard(report(id), config(server, id)) =~
               "The guard added nothing: #{inspect(server)} held no open log capture"

      assert {:error, {:not_found, ^id}} = :logger.get_handler_config(id)
    end

    test "with a state that has no log_captures map, prints so, adds nothing and leaves the " <>
           "server and its state as they were",
         %{id: id} do
      for {state, shape} <- [
            {%{devices: %{}}, "a map with keys [:devices]"},
            {%{log_captures: [:a_ref]}, "a map with keys [:log_captures]"},
            {{:state, %{log_captures: %{}}}, "{:state, %{log_captures: %{}}}"}
          ] do
        server = start_supervised!({Agent, fn -> state end}, id: make_ref())
        monitor = Process.monitor(server)

        assert run_guard(report(id), config(server, id)) =~
                 "The guard added nothing: the state of #{inspect(server)} is not a map with " <>
                   "a log_captures map, as in Elixir 1.20.5, but #{shape}. File a needs-triage"

        assert {:error, {:not_found, ^id}} = :logger.get_handler_config(id)
        # `Agent.get/2` answers only after the server handled the guard's request.
        assert Agent.get(server, & &1) == state
        refute_received {:DOWN, ^monitor, :process, ^server, _reason}
      end
    end

    test "with no server running, prints that replace_state failed", %{id: id} do
      server = :cinder_capture_server_guard_test_no_server

      assert run_guard(report(id), config(server, id)) =~
               "The guard added nothing: :sys.replace_state/3 on " <>
                 ":cinder_capture_server_guard_test_no_server failed with :exit {:noproc,"

      assert {:error, {:not_found, ^id}} = :logger.get_handler_config(id)
    end

    test "ignores a removal of another handler, another logger report and other events",
         %{id: id} do
      server = start_supervised!({Agent, fn -> %{log_captures: %{make_ref() => true}} end})
      config = config(server, id)
      other = List.keystore(report(id), :handler, 0, {:handler, {:other_handler, NoopHandler}})
      failed = List.keystore(report(id), :logger, 0, {:logger, :remove_handler_failed})

      assert run_guard(other, config) == ""
      assert run_guard(failed, config) == ""

      for msg <- [{:string, "removed_failing_handler"}, {:report, %{logger: :x}}] do
        assert CaptureServerGuard.log(%{level: :error, msg: msg, meta: %{}}, %{config: config}) ==
                 :ok
      end

      assert {:error, {:not_found, ^id}} = :logger.get_handler_config(id)
      # The control: the same server and config add the handler on the removal of `id`.
      assert run_guard(report(id), config) =~ "The guard added it back"
    end

    test "names what the report leaves out, and keeps a long reason on one line", %{id: id} do
      server = start_supervised!({Agent, fn -> %{log_captures: %{}} end})
      config = config(server, id)
      no_meta = %{level: :warning, msg: {:string, "x"}, meta: %{}}
      line_only = %{no_meta | meta: %{line: 12}}
      stack = for n <- 1..200, do: {Foo, :"fun_#{n}", 1, [file: ~c"lib/foo.ex", line: n]}
      message = "a\nmultiline\n" <> String.duplicate("x", 2000)
      reason = {:error, %RuntimeError{message: message}, stack}

      assert run_guard(report(id, log_event: no_meta), config) =~
               "failed on :warning event from an unknown pid at an unknown call site, with reason"

      assert run_guard(report(id, log_event: line_only), config) =~
               "from an unknown pid at line 12, with reason"

      assert run_guard(List.keydelete(report(id), :log_event, 0), config) =~
               "after it failed on an event the report does not include, with reason"

      assert run_guard(List.keydelete(report(id), :reason, 0), config) =~
               "line 7, with reason unknown. The guard"

      long = run_guard(report(id, reason: reason), config)
      assert long =~ "with reason {:error, %RuntimeError{message: \"a\\nmultiline\\nxxx"
      assert [_one] = String.split(long, "\n", trim: true)
      # `inspect/2`'s `printable_limit: 1000` cuts the message, and `limit: 50`, which counts
      # the items of every nested collection together, cuts the stack after its seventh entry.
      assert long =~ String.duplicate("x", 985)
      refute long =~ String.duplicate("x", 990)
      assert long =~ "{Foo, :fun_6, 1, [file: ~c\"lib/foo.ex\", line: 6]}"
      refute long =~ ":fun_8,"
      assert String.ends_with?(long, "(#1716).\n")
    end

    test "returns :ok when it cannot write its line", %{id: id} do
      server = start_supervised!({Agent, fn -> %{log_captures: %{}} end})
      {:ok, io} = StringIO.open("")
      {:ok, _} = StringIO.close(io)

      assert CaptureServerGuard.log(
               %{level: :debug, msg: {:report, report(id)}, meta: %{}},
               %{config: Map.put(config(server, id), :device, io)}
             ) == :ok
    end
  end

  defp config(server, id), do: %{server: server, handler_id: id, handler_module: NoopHandler}

  defp report(handler_id, opts \\ []) do
    event = %{
      level: :error,
      msg: {:string, "x"},
      meta: %{pid: self(), mfa: {Foo, :bar, 2}, file: ~c"test/foo_test.exs", line: 7}
    }

    [
      logger: :removed_failing_handler,
      handler: {handler_id, NoopHandler},
      log_event: Keyword.get(opts, :log_event, event),
      config: %{},
      reason: Keyword.get(opts, :reason, {:exit, {:timeout, {Task, :await_many, [[], 5000]}}, []})
    ]
  end

  defp run_guard(report, config) do
    {:ok, io} = StringIO.open("")
    event = %{level: :debug, msg: {:report, report}, meta: %{pid: self()}}
    assert CaptureServerGuard.log(event, %{config: Map.put(config, :device, io)}) == :ok
    {:ok, {"", out}} = StringIO.close(io)
    out
  end

  # Points the installed guard at a StringIO until the test ends, so this run's stderr gets no
  # line that asks for an issue. With no guard installed it changes nothing.
  defp swap_guard_device do
    {:ok, io} = StringIO.open("")

    case :logger.get_handler_config(CaptureServerGuard) do
      {:ok, %{config: config}} ->
        :ok = :logger.update_handler_config(CaptureServerGuard, :config, %{config | device: io})
        on_exit(fn -> :logger.update_handler_config(CaptureServerGuard, :config, config) end)

      {:error, _} ->
        :ok
    end

    io
  end

  defp wait_for_line(io) do
    eventually(fn -> String.ends_with?(elem(StringIO.contents(io), 1), "\n") end, 10_000)
    elem(StringIO.contents(io), 1)
  end

  # A mutant that adds the handler with no capture open leaves it behind, and CaptureServer then
  # crashes on every later capture's add: this keeps that crash inside the test that caused it.
  defp remove_stray_capture_handler do
    if open_captures() == 0, do: :logger.remove_handler(@server)
  end

  defp open_captures, do: map_size(:sys.get_state(@server).log_captures)

  defp logger_state do
    {Enum.sort(:logger.get_handler_ids()), Enum.sort(:logger.get_module_level()),
     :logger.get_primary_config().level, :logger.get_handler_config(CaptureServerGuard)}
  end

  # Polls `fun` every 20 ms until it returns true or `timeout_ms` passes, and returns its last
  # answer.
  defp eventually(fun, timeout_ms \\ 5_000) do
    poll(fun, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(20) && poll(fun, deadline)
    end
  end
end
