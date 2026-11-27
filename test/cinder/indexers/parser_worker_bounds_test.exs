defmodule Cinder.Indexers.ParserWorkerBoundsTest do
  # Each test points `:parser_worker_erl` at a stub shell script in place of the real `erl`, so
  # it runs under the same `env -i` and `ulimit` wrapper with the same arguments. The key is
  # global, so the module is not async.
  use ExUnit.Case, async: false

  alias Cinder.ConfigCase
  alias Cinder.Indexers.Definitions.LoadCheck
  alias Cinder.Indexers.ParserWorker
  alias Cinder.Test.OsProcess

  @moduletag :tmp_dir

  @plan %{rows: "td", fields: [%{name: "t", selector: nil, attribute: nil, remove: [], case: []}]}

  # The stubs put tmp_dir paths into sh unquoted, and tmp_dir holds the test name.
  defp stub!(tmp, body) do
    if tmp =~ ~r/[^A-Za-z0-9_\/.,-]/,
      do: raise(ArgumentError, "rename the test: sh misreads its tmp_dir #{inspect(tmp)}")

    path = Path.join(tmp, "erl-#{System.unique_integer([:positive])}")
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    ConfigCase.put_env(:parser_worker_erl, path)
    path
  end

  # A stub that answers with the bytes of `answer`, framed as the worker frames its answer, on
  # descriptor 3 as the worker does.
  defp answering_stub!(tmp, answer) do
    file = Path.join(tmp, "answer-#{System.unique_integer([:positive])}")
    File.write!(file, <<byte_size(answer)::32, answer::binary>>)
    stub!(tmp, "cat #{file} >&3")
  end

  defp run(opts \\ []),
    do: ParserWorker.run("<td>x</td>", @plan, Keyword.merge([deadline_ms: 20_000], opts))

  defp write_pid(pidfile), do: "echo $$ > #{pidfile}.tmp && mv #{pidfile}.tmp #{pidfile}"

  test "a stub answering a valid frame reads as rows: the framing the other cases break", %{
    tmp_dir: tmp
  } do
    answering_stub!(tmp, <<?R, 1::32, 1::32, 1, 1::32, "x">>)
    assert run() == {:ok, [[{"t", "x"}]]}
  end

  # The release image's VM prints `=ESOCK WARNING MSG` to its stdout on every start.
  test "what the worker prints to its stdout never reaches its answer", %{tmp_dir: tmp} do
    file = Path.join(tmp, "answer")
    answer = <<?R, 1::32, 1::32, 1, 1::32, "x">>
    File.write!(file, <<byte_size(answer)::32, answer::binary>>)
    stub!(tmp, "echo '=ESOCK WARNING MSG===='\ncat #{file} >&3\necho after")
    assert run() == {:ok, [[{"t", "x"}]]}
  end

  test "a worker held past its deadline is killed with its process group and reads :timeout", %{
    tmp_dir: tmp
  } do
    child_pidfile = Path.join(tmp, "child.pid")
    pidfile = Path.join(tmp, "stub.pid")

    stub!(tmp, """
    #{write_pid(pidfile)}
    sh -c '#{write_pid(child_pidfile)}; exec sleep 30' &
    exec sleep 30
    """)

    started = System.monotonic_time(:millisecond)
    assert run(deadline_ms: 1_500) == {:error, :timeout}
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 1_500 and elapsed < 10_000

    {:ok, pid} = OsProcess.await_record(pidfile)
    assert OsProcess.dead?(pid |> String.trim() |> String.to_integer())

    case OsProcess.await_record(child_pidfile) do
      {:ok, child} -> assert OsProcess.dead?(child |> String.trim() |> String.to_integer())
      :none -> :ok
    end
  end

  test "a worker past the memory cap reads :memory long before its deadline", %{tmp_dir: tmp} do
    pidfile = Path.join(tmp, "stub.pid")
    stub!(tmp, "#{write_pid(pidfile)}\nexec sleep 30")

    started = System.monotonic_time(:millisecond)
    assert run(deadline_ms: 30_000, max_memory_bytes: 100_000) == {:error, :memory}
    assert System.monotonic_time(:millisecond) - started < 15_000

    {:ok, pid} = OsProcess.await_record(pidfile)
    assert OsProcess.dead?(pid |> String.trim() |> String.to_integer())
  end

  test "a worker under the memory cap is left to answer", %{tmp_dir: tmp} do
    answering_stub!(tmp, <<?R, 0::32, 1::32>>)
    assert run(max_memory_bytes: 1_000_000_000) == {:ok, []}
  end

  test "a worker answering past the output cap reads :output_too_large", %{tmp_dir: tmp} do
    stub!(tmp, "head -c 100 /dev/zero >&3\nexec sleep 30")
    assert run(max_output_bytes: 99) == {:error, :output_too_large}
  end

  describe "reads :crash" do
    # An exit before reading the input is the trap-exits test below: only an input larger than
    # the pipe buffer meets the closed pipe.
    test "on a non-zero exit or a signal", %{tmp_dir: tmp} do
      for body <- ["exit 3", "kill -SEGV $$"] do
        stub!(tmp, body)
        assert run() == {:error, :crash}, body
      end
    end

    test "on an exit 0 answer that is not one frame", %{tmp_dir: tmp} do
      answer = <<?R, 0::32, 1::32>>

      for output <- [
            "",
            "garbage",
            <<byte_size(answer) + 1::32, answer::binary>>,
            <<byte_size(answer)::32, answer::binary, 0>>
          ] do
        file = Path.join(tmp, "out-#{System.unique_integer([:positive])}")
        File.write!(file, output)
        stub!(tmp, "cat #{file} >&3")
        assert run() == {:error, :crash}, inspect(output)
      end
    end

    test "on a frame that does not read as rows of the plan", %{tmp_dir: tmp} do
      for answer <- [
            <<>>,
            "Z",
            :erlang.term_to_binary({:ok, []}),
            <<?R, 1::32, 2::32, 0, 0>>,
            <<?R, 1::32, 1::32>>,
            <<?R, 1::32, 1::32, 0, 0>>,
            <<?R, 1::32, 1::32, 9>>,
            <<?R, 1::32, 1::32, 1, 5::32, "x">>,
            <<?R, 1::32, 1::32, 2, 0::32>>,
            <<?X, 2::32>>
          ] do
        answering_stub!(tmp, answer)
        assert run() == {:error, :crash}, inspect(answer)
      end
    end

    test "on a case index past the case selectors of its field", %{tmp_dir: tmp} do
      plan = %{
        rows: "tr",
        fields: [%{name: "c", selector: nil, attribute: nil, remove: [], case: ["b", "i"]}]
      }

      answering_stub!(tmp, <<?R, 1::32, 1::32, 2, 2::32>>)
      assert ParserWorker.run("x", plan, deadline_ms: 20_000) == {:error, :crash}
    end

    test "on more rows than the output cap for a plan with no fields", %{tmp_dir: tmp} do
      plan = %{rows: "tr", fields: []}
      cap = ParserWorker.max_output_bytes()

      answering_stub!(tmp, <<?R, cap::32, 0::32>>)
      assert {:ok, rows} = ParserWorker.run("x", plan, deadline_ms: 20_000)
      assert length(rows) == cap

      answering_stub!(tmp, <<?R, cap + 1::32, 0::32>>)
      assert ParserWorker.run("x", plan, deadline_ms: 20_000) == {:error, :crash}
    end

    test "on a check answer of the wrong length or with an unknown verdict", %{tmp_dir: tmp} do
      for answer <- [<<?C, 2::32, 0, 0>>, <<?C, 1::32, 2>>, <<?C, 1::32>>, <<?R, 0::32, 0::32>>] do
        answering_stub!(tmp, answer)
        assert ParserWorker.check_selectors(["td"]) == {:error, :crash}, inspect(answer)
      end
    end

    test "in a caller that traps no exits, which goes on with an empty mailbox", %{tmp_dir: tmp} do
      stub!(tmp, "exec 0<&-\nexec sleep 30")
      html = String.duplicate("<td>x</td>", 100_000)

      task =
        Task.async(fn ->
          result = ParserWorker.run(html, @plan, deadline_ms: 20_000)
          {result, Process.info(self(), :messages), Process.info(self(), :trap_exit)}
        end)

      assert Task.await(task, 30_000) == {{:error, :crash}, {:messages, []}, {:trap_exit, false}}
    end
  end

  test "an answer whose refusal names a field reads where it sits", %{tmp_dir: tmp} do
    answering_stub!(tmp, <<?X, 1::32>>)
    assert run() == {:error, {:refused, {:field, 0}}}

    answering_stub!(tmp, <<?X, 0::32>>)
    assert run() == {:error, {:refused, :rows}}
  end

  test "a case index reads as its selector", %{tmp_dir: tmp} do
    plan = %{
      rows: "tr",
      fields: [%{name: "c", selector: nil, attribute: nil, remove: [], case: ["b", "i"]}]
    }

    answering_stub!(tmp, <<?R, 1::32, 1::32, 2, 1::32>>)
    assert ParserWorker.run("x", plan, deadline_ms: 20_000) == {:ok, [[{"c", {:case, "i"}}]]}
  end

  describe "the command" do
    test "has an environment of PATH and ERL_CRASH_DUMP_BYTES only, so no secret reaches it", %{
      tmp_dir: tmp
    } do
      envfile = Path.join(tmp, "env")
      argsfile = Path.join(tmp, "args")
      System.put_env("CINDER_PARSER_WORKER_TEST_SECRET", "hunter2")
      on_exit(fn -> System.delete_env("CINDER_PARSER_WORKER_TEST_SECRET") end)
      erl = stub!(tmp, "env > #{envfile}\nprintf '%s\\0' \"$@\" > #{argsfile}\nexit 1")

      assert run() == {:error, :crash}

      names =
        envfile
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&(&1 |> String.split("=", parts: 2) |> hd()))
        |> Enum.sort()

      # sh adds PWD (and, in some shells, SHLVL and `_`) to what `env -i` hands it.
      assert names -- ["PWD", "SHLVL", "_"] == ["ERL_CRASH_DUMP_BYTES", "PATH"]
      assert File.read!(envfile) =~ "ERL_CRASH_DUMP_BYTES=0\n"
      refute File.read!(envfile) =~ "hunter2"

      args = argsfile |> File.read!() |> String.split("\0", trim: true)
      root = List.to_string(:code.root_dir())
      ebin = fn app -> Path.join(List.to_string(:code.lib_dir(app)), "ebin") end

      assert args == [
               "-noshell",
               "-noinput",
               "+S",
               "1:1",
               "+fnu",
               "-boot",
               root <> "/bin/no_dot_erlang",
               "-pa",
               ebin.(:elixir),
               "-pa",
               ebin.(:lazy_html),
               "-pa",
               ebin.(:cinder),
               "-run",
               "Elixir.Cinder.Indexers.ParserWorker",
               "child"
             ]

      assert ParserWorker.command_args(20_000) |> Enum.drop_while(&(&1 != erl)) |> tl() == args
    end

    test "runs under ulimit -v of 4 GiB, ulimit -t of the deadline in seconds plus 2, and " <>
           "ulimit -c of 0",
         %{tmp_dir: tmp} do
      limits = Path.join(tmp, "limits")
      stub!(tmp, "ulimit -v > #{limits}\nulimit -t >> #{limits}\nulimit -c >> #{limits}\nexit 1")

      assert run(deadline_ms: 1_500) == {:error, :crash}
      assert File.read!(limits) == "4194304\n4\n0\n"

      assert run(deadline_ms: 2_000) == {:error, :crash}
      assert File.read!(limits) == "4194304\n4\n0\n"

      assert run(deadline_ms: 2_001) == {:error, :crash}
      assert File.read!(limits) == "4194304\n5\n0\n"
    end

    # The command runs under a hard address-space limit below the worker's, so its own
    # `ulimit -v` fails.
    test "never starts the worker when a limit cannot be set", %{tmp_dir: tmp} do
      marker = Path.join(tmp, "ran")
      stub!(tmp, "touch #{marker}")
      under_limit = ~s(ulimit -H -v 1000000 && exec env "$@")

      {output, status} =
        System.cmd("/bin/sh", ["-c", under_limit, "sh" | ParserWorker.command_args(5_000)],
          stderr_to_stdout: true
        )

      assert status != 0, output
      refute File.exists?(marker)
    end

    test "carries a fresh 128-bit marker token per worker", %{tmp_dir: tmp} do
      inputs =
        for n <- 1..2 do
          capture = Path.join(tmp, "input-#{n}")
          stub!(tmp, "timeout 1 cat > #{capture}\nexit 1")

          ParserWorker.run("<td>x</td>", %{@plan | rows: ~S|td:contains("x")|},
            deadline_ms: 20_000
          )

          <<size::32, payload::binary-size(size)>> = File.read!(capture)

          {:run, "<td>x</td>", rows, _fields, marks, nil, _extras, 20_000} =
            :erlang.binary_to_term(payload)

          [_all, token] = Regex.run(~r/\Atd\[cinder-([0-9a-f]{32})-r-c0\]\z/, rows)
          assert marks == [{"cinder-#{token}-r-c0", "x"}]
          token
        end

      assert [a, b] = inputs
      assert a != b
    end
  end

  describe "check workers" do
    test "at most 2 run at once, and the third waits for a slot", %{tmp_dir: tmp} do
      started = Path.join(tmp, "started")
      release = Path.join(tmp, "release")
      File.mkdir_p!(started)
      answer = Path.join(tmp, "answer")
      check = <<?C, 1::32, 0>>
      File.write!(answer, <<byte_size(check)::32, check::binary>>)

      stub!(tmp, """
      touch #{started}/$$
      i=0
      while [ ! -e #{release} ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i+1)); done
      cat #{answer} >&3
      """)

      tasks = for _n <- 1..3, do: Task.async(fn -> ParserWorker.check_selectors(["td"]) end)
      count = fn -> started |> File.ls!() |> length() end

      assert Enum.find_value(1..200, fn _attempt ->
               count.() >= 2 || (Process.sleep(50) && nil)
             end)

      Process.sleep(1_000)
      assert count.() == 2

      File.write!(release, "")
      assert Enum.map(tasks, &Task.await(&1, 30_000)) == List.duplicate({:ok, [{"td", :ok}]}, 3)
      assert count.() == 3
    end

    # The test process makes the first call and lives on, so only the release on return frees
    # its slot for the two tasks.
    test "a slot frees when its call returns, while its caller lives on", %{tmp_dir: tmp} do
      answer = Path.join(tmp, "answer")
      check = <<?C, 1::32, 0>>
      File.write!(answer, <<byte_size(check)::32, check::binary>>)
      stub!(tmp, "cat #{answer} >&3")
      assert ParserWorker.check_selectors(["td"]) == {:ok, [{"td", :ok}]}

      started = Path.join(tmp, "started")
      release = Path.join(tmp, "release")
      File.mkdir_p!(started)

      stub!(tmp, """
      touch #{started}/$$
      i=0
      while [ ! -e #{release} ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i+1)); done
      cat #{answer} >&3
      """)

      tasks = for _n <- 1..2, do: Task.async(fn -> ParserWorker.check_selectors(["td"]) end)
      count = fn -> started |> File.ls!() |> length() end

      assert Enum.find_value(1..200, fn _attempt ->
               count.() >= 2 || (Process.sleep(50) && nil)
             end)

      File.write!(release, "")
      assert Enum.map(tasks, &Task.await(&1, 30_000)) == List.duplicate({:ok, [{"td", :ok}]}, 2)
    end

    test "a crash marks the copy {:selector, :crash} and a timeout {:selector, :timeout}", %{
      tmp_dir: tmp
    } do
      yaml =
        Jason.encode!(%{
          "id" => "cindertest",
          "name" => "Cinder Test",
          "description" => "Written for Cinder's tests",
          "language" => "en-US",
          "type" => "public",
          "encoding" => "UTF-8",
          "links" => ["https://tracker.invalid/"],
          "settings" => [],
          "caps" => %{"modes" => %{"search" => ["q"]}},
          "search" => %{
            "rows" => %{"selector" => "tr"},
            "fields" => %{"t" => %{"selector" => "a"}}
          }
        })

      stub!(tmp, "kill -SEGV $$")
      assert {:ok, %{unsupported: [{:selector, :crash}]}} = LoadCheck.check(yaml)

      stub!(tmp, "exec sleep 30")

      assert {:ok, %{unsupported: [{:selector, :timeout}]}} =
               LoadCheck.check(yaml, deadline_ms: 1_000)
    end
  end
end
