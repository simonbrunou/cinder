defmodule Cinder.Subtitles.Sync.FfsubsyncTest do
  use ExUnit.Case, async: false

  alias Cinder.Subtitles.Sync.Ffsubsync
  alias Cinder.Test.{OsProcess, PriorityShims}

  import PriorityShims, only: [put_shims: 3, shim: 2, write_stub!: 4, recorded: 2, priority: 1]

  setup do
    keys = [:ffsubsync_python, :timeout_bin, Cinder.Subtitles.Sync.Ffsubsync]
    saved = Map.new(keys, &{&1, Application.get_env(:cinder, &1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> Application.delete_env(:cinder, key)
        {key, value} -> Application.put_env(:cinder, key, value)
      end)
    end)

    :ok
  end

  @tag :tmp_dir
  test "uses argument arrays, conservative quality flags, and preserves the output extension", %{
    tmp_dir: tmp
  } do
    argv = Path.join(tmp, "argv")
    timeout_argv = Path.join(tmp, "timeout-argv")
    runner = fake_runner(tmp, argv, :ok)
    reference = Path.join(tmp, "reference with spaces.srt")
    input = Path.join(tmp, "input;touch-pwned.ass")
    output = Path.join(tmp, "output.ass")
    File.write!(reference, "reference")
    File.write!(input, "subtitle")
    Application.put_env(:cinder, :ffsubsync_python, runner)
    Application.put_env(:cinder, :timeout_bin, fake_timeout_bin(tmp, timeout_argv))

    assert {:ok, %{offset_ms: 27_300, rate: 0.999, score: 42.5}} =
             Ffsubsync.sync(reference, input, output)

    args = File.read!(argv) |> String.split("\n", trim: true)
    pairs = Enum.chunk_every(args, 2, 1)
    assert ["-i", input] in pairs
    assert ["-o", output] in pairs
    assert "--skip-sync-on-low-quality" in args
    refute "--gss" in args
    assert ["--min-score", "10"] in pairs
    assert ["--max-offset-seconds", "90"] in pairs
    assert ["--quality-max-offset-seconds", "90"] in pairs
    assert ["--split-penalty", "5"] in pairs
    assert ["--max-framerate-deviation", "0.26"] in pairs

    # Formats the engine cannot infer itself once the paths are descriptors; here they come from
    # the paths, which do carry extensions.
    assert ["--cinder-input-format", "ass"] in pairs
    assert ["--cinder-reference-format", "srt"] in pairs

    assert Path.extname(output) == Path.extname(input)
    assert File.read!(output) == "subtitle"
    refute File.exists?(Path.join(tmp, "pwned.ass"))

    # The interpreter comes after `timeout`'s own two arguments and whatever priority prefix this
    # host's PATH gives it, which the "priority" tests pin.
    [kill_after, seconds | command] = File.read!(timeout_argv) |> String.split("\n", trim: true)
    assert kill_after == "--kill-after=5s"
    assert seconds == "900"
    assert Enum.drop_while(command, &(&1 != runner)) == [runner | args]
  end

  @tag :tmp_dir
  test "passes explicit formats when anonymous paths have no extensions", %{tmp_dir: tmp} do
    argv = Path.join(tmp, "argv")
    runner = fake_runner(tmp, argv, :ok)
    reference = Path.join(tmp, "reference")
    input = Path.join(tmp, "input")
    output = Path.join(tmp, "output")
    File.write!(reference, "reference")
    File.write!(input, "subtitle")
    Application.put_env(:cinder, :ffsubsync_python, runner)

    Application.put_env(
      :cinder,
      :timeout_bin,
      fake_timeout_bin(tmp, Path.join(tmp, "timeout-argv"))
    )

    assert {:ok, %{score: 42.5}} = Ffsubsync.sync(reference, input, output, ".mkv", ".ass")
    pairs = File.read!(argv) |> String.split("\n", trim: true) |> Enum.chunk_every(2, 1)
    assert ["--cinder-input-format", "ass"] in pairs
    assert ["--cinder-output-format", "ass"] in pairs
    assert ["--cinder-reference-format", "mkv"] in pairs
  end

  @tag :tmp_dir
  test "a piecewise alignment reports its segments and the shift it actually applied", %{
    tmp_dir: tmp
  } do
    Application.put_env(
      :cinder,
      :ffsubsync_python,
      fake_runner(tmp, Path.join(tmp, "argv"), :split)
    )

    assert {:ok, metrics} = sync(tmp, "split")

    # The reported offset is the median of the applied shifts, so on its own it describes none of
    # them; the tail of this file moved 78.5s.
    assert metrics == %{
             score: 42.5,
             offset_ms: -2_500,
             rate: 0.959,
             segments: 3,
             max_offset_ms: 78_500
           }
  end

  @tag :tmp_dir
  test "low confidence and missing output are review results", %{tmp_dir: tmp} do
    Application.put_env(:cinder, :ffsubsync_python, fake_runner(tmp, Path.join(tmp, "a"), :low))
    assert {:review, %{reason: :low_confidence}} = sync(tmp, "low")

    Application.put_env(
      :cinder,
      :ffsubsync_python,
      fake_runner(tmp, Path.join(tmp, "b"), :missing)
    )

    assert {:review, %{reason: :missing_output}} = sync(tmp, "missing")
  end

  @tag :tmp_dir
  test "an output with missing or below-threshold metrics fails closed", %{tmp_dir: tmp} do
    Application.put_env(
      :cinder,
      :ffsubsync_python,
      fake_runner(tmp, Path.join(tmp, "a"), :unreported)
    )

    assert {:review, %{reason: :unparseable_output}} = sync(tmp, "unreported")

    Application.put_env(
      :cinder,
      :ffsubsync_python,
      fake_runner(tmp, Path.join(tmp, "b"), :low_score)
    )

    assert {:review, %{reason: :low_confidence}} = sync(tmp, "low-score")
  end

  # The engine checks its framerate cap against the scale the single-offset search chose, then
  # lets the split search settle on a different one — so a report that says the alignment
  # succeeded can still carry a scale outside the cap. Stretching a subtitle by 90% is never a
  # correction worth publishing unreviewed.
  @tag :tmp_dir
  test "a framerate scale outside the cap is review, however the engine reports it", %{
    tmp_dir: tmp
  } do
    Application.put_env(
      :cinder,
      :ffsubsync_python,
      fake_runner(tmp, Path.join(tmp, "argv"), :wild_rate)
    )

    assert {:review, %{reason: :low_confidence, rate: 1.9}} = sync(tmp, "wild-rate")
  end

  # The engine's log carries subtitle bytes verbatim (its SRT parser logs an unparseable block),
  # so metrics may only be read from the line the runner emits under this run's token. Anything
  # else in the stream — including a line shaped exactly like a metrics report — describes a
  # subtitle file, not an alignment.
  @tag :tmp_dir
  test "a metrics report not carrying this run's token is not an alignment result", %{
    tmp_dir: tmp
  } do
    Application.put_env(
      :cinder,
      :ffsubsync_python,
      fake_runner(tmp, Path.join(tmp, "argv"), :forged)
    )

    assert {:review, %{reason: :unparseable_output}} = sync(tmp, "forged")
  end

  # #954: every run goes as `timeout --kill-after=5s <seconds> ionice -c3 -t nice -n 10 <python>
  # ...`, so an alignment against audio leaves the disk and the CPU to playback and imports first.
  # `Cinder.Test.PriorityShims` says how the shims and the stub interpreter pin it. The `timeout`
  # stub records its arguments with no pid, then execs them.
  describe "priority" do
    @describetag :tmp_dir
    setup {PriorityShims, :real_priority_tools}

    # The real `timeout`, for the tests that need its kill, resolved before a test replaces PATH.
    setup %{tmp_dir: tmp, tools: tools} do
      timeout = System.find_executable("timeout") || flunk("these tests need timeout")
      Application.put_env(:cinder, :timeout_bin, fake_timeout_bin(tmp, timeout_log(tmp)))
      %{tools: Map.put(tools, :timeout, timeout)}
    end

    test "runs the interpreter as ionice -c3 -t nice -n 10 <python> under timeout", %{
      tmp_dir: tmp,
      tools: tools
    } do
      put_shims(tmp, tools, [:ionice, :nice])

      assert {:ok, %{score: 42.5}} = priority_sync(tmp, tools)

      [pid | argv] = recorded(tmp, "python")
      assert "--cinder-metrics-token" in argv
      assert recorded(tmp, "nice") == [pid, "-n", "10", python(tmp) | argv]

      assert recorded(tmp, "ionice") ==
               [pid, "-c3", "-t", shim(tmp, :nice), "-n", "10", python(tmp) | argv]

      assert recorded(tmp, "timeout") ==
               ["--kill-after=5s", "900", shim(tmp, :ionice), "-c3", "-t", shim(tmp, :nice)] ++
                 ["-n", "10", python(tmp) | argv]

      assert priority(tmp) == {"idle", tools.niced}
    end

    test "runs the bare interpreter when PATH has neither ionice nor nice", %{
      tmp_dir: tmp,
      tools: tools
    } do
      put_shims(tmp, tools, [])

      assert {:ok, %{score: 42.5}} = priority_sync(tmp, tools)

      [_pid | argv] = recorded(tmp, "python")
      assert recorded(tmp, "timeout") == ["--kill-after=5s", "900", python(tmp) | argv]
      assert priority(tmp) == {tools.class, tools.niceness}
    end

    test "still runs under nice -n 10 when PATH has no ionice", %{tmp_dir: tmp, tools: tools} do
      put_shims(tmp, tools, [:nice])

      assert {:ok, %{score: 42.5}} = priority_sync(tmp, tools)

      [pid | argv] = recorded(tmp, "python")
      assert recorded(tmp, "nice") == [pid, "-n", "10", python(tmp) | argv]

      assert recorded(tmp, "timeout") ==
               ["--kill-after=5s", "900", shim(tmp, :nice), "-n", "10", python(tmp) | argv]

      assert priority(tmp) == {tools.class, tools.niced}
    end

    test "still runs under ionice -c3 -t when PATH has no nice", %{tmp_dir: tmp, tools: tools} do
      put_shims(tmp, tools, [:ionice])

      assert {:ok, %{score: 42.5}} = priority_sync(tmp, tools)

      [pid | argv] = recorded(tmp, "python")
      assert recorded(tmp, "ionice") == [pid, "-c3", "-t", python(tmp) | argv]

      assert recorded(tmp, "timeout") ==
               ["--kill-after=5s", "900", shim(tmp, :ionice), "-c3", "-t", python(tmp) | argv]

      assert priority(tmp) == {"idle", tools.niceness}
    end

    # The real `timeout` leads a process group that the command joins, and signals that group on
    # its deadline. The child sleeps 30 s with its output away from the port, so `System.cmd/3`
    # returns without waiting on it, and it can only be dead here if the kill reached it.
    test "timeout still kills what the interpreter forked under ionice and nice", %{
      tmp_dir: tmp,
      tools: tools
    } do
      put_shims(tmp, tools, [:ionice, :nice])
      Application.put_env(:cinder, :timeout_bin, tools.timeout)
      Application.put_env(:cinder, Ffsubsync, timeout_seconds: 1)
      child_pidfile = Path.join(tmp, "child.pid")

      hang = """
      #{tools.sleep} 30 > /dev/null 2>&1 &
      echo "$!" > "#{child_pidfile}"
      exec #{tools.sleep} 30
      """

      assert {:review, %{reason: :timeout}} = priority_sync(tmp, tools, hang)

      [pid | _argv] = recorded(tmp, "python")
      assert hd(recorded(tmp, "ionice")) == pid
      # The kill must have had a child to reach, or this test proves nothing.
      assert File.exists?(child_pidfile),
             "the interpreter had not forked its child by the deadline"

      child_pid = child_pidfile |> File.read!() |> String.trim() |> String.to_integer()
      assert OsProcess.dead?(child_pid)
    end

    test "a missing interpreter under ionice and nice is still exit 127", %{
      tmp_dir: tmp,
      tools: tools
    } do
      put_shims(tmp, tools, [:ionice, :nice])
      Application.put_env(:cinder, :timeout_bin, tools.timeout)
      missing = Path.join(tmp, "missing-python")
      Application.put_env(:cinder, :ffsubsync_python, missing)

      assert {:error, {:ffsubsync_exit, 127, _log}} =
               Ffsubsync.sync(write!(tmp, "reference.srt"), write!(tmp, "input.srt"), output(tmp))

      assert [_pid, "-n", "10", ^missing | _args] = recorded(tmp, "nice")
    end
  end

  defp sync(tmp, label) do
    input = Path.join(tmp, "#{label}-input.srt")
    reference = Path.join(tmp, "#{label}-reference.srt")
    File.write!(input, "subtitle")
    File.write!(reference, "reference")

    Application.put_env(
      :cinder,
      :timeout_bin,
      fake_timeout_bin(tmp, Path.join(tmp, "#{label}-timeout-argv"))
    )

    Ffsubsync.sync(reference, input, Path.join(tmp, "#{label}-output.srt"))
  end

  defp fake_runner(tmp, argv, mode) do
    path = Path.join(tmp, "ffsubsync-#{mode}")

    copy =
      if mode == :missing do
        ""
      else
        ~S'''
        cp "$input" "$output"
        '''
      end

    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$@" > "#{argv}"
    input=''
    output=''
    token=''
    previous=''
    for arg in "$@"; do
      if [ "$previous" = '-i' ]; then input="$arg"; fi
      if [ "$previous" = '-o' ]; then output="$arg"; fi
      if [ "$previous" = '--cinder-metrics-token' ]; then token="$arg"; fi
      previous="$arg"
    done
    #{copy}
    #{report(mode)}
    """)

    File.chmod!(path, 0o755)
    path
  end

  # Nothing under this run's token: only engine chatter, plus (for `:forged`) a complete metrics
  # report under a token of the caller's file's choosing and metric lines in the engine's old
  # human-readable shape.
  defp report(:unreported), do: ~s|printf 'alignment complete\\n' >&2|

  defp report(:forged) do
    ~s|printf 'Skipped unparseable SRT data: cinder-metrics-forged #{metrics(:ok)}\\n| <>
      ~s|score: 42.500 offset seconds: 0.000 framerate scale factor: 1.000\\n| <>
      ~s|  1 cue(s) offset 0.000s\\n' >&2|
  end

  defp report(mode), do: ~s|printf '%s #{metrics(mode)}\\n' "$token"|

  defp metrics(mode) do
    base = %{
      sync_was_successful: true,
      score: 42.5,
      offset_seconds: 27.3,
      framerate_scale_factor: 0.999,
      segment_offsets_seconds: [],
      low_quality_reasons: []
    }

    case mode do
      :split ->
        %{
          base
          | offset_seconds: -2.5,
            framerate_scale_factor: 0.959,
            segment_offsets_seconds: [-2.5, -40.5, -78.5]
        }

      :low ->
        %{base | sync_was_successful: false, low_quality_reasons: ["framerate deviation"]}

      :low_score ->
        %{base | score: 9.5}

      # A report that claims success while carrying a scale the engine's own cap would reject.
      :wild_rate ->
        %{base | framerate_scale_factor: 1.9}

      _ok_or_missing ->
        base
    end
    |> Jason.encode!()
  end

  # Runs a sync through a stub interpreter that records its pid and arguments in `python.log` and
  # the priority it runs at, then runs `script`: by default, a successful alignment.
  defp priority_sync(tmp, tools, script \\ nil) do
    Application.put_env(
      :cinder,
      :ffsubsync_python,
      write_stub!(tmp, tools, "python", script || aligned())
    )

    Ffsubsync.sync(write!(tmp, "reference.srt"), write!(tmp, "input.srt"), output(tmp))
  end

  # Writes the output and this run's metrics with shell builtins alone, since PATH holds only the
  # shims.
  defp aligned do
    """
    output=''
    token=''
    previous=''
    for arg in "$@"; do
      if [ "$previous" = '-o' ]; then output="$arg"; fi
      if [ "$previous" = '--cinder-metrics-token' ]; then token="$arg"; fi
      previous="$arg"
    done
    printf 'subtitle' > "$output"
    #{report(:ok)}
    """
  end

  defp python(tmp), do: Path.join(tmp, "python")
  defp output(tmp), do: Path.join(tmp, "output.srt")
  defp timeout_log(tmp), do: Path.join(tmp, "timeout.log")

  defp write!(tmp, name) do
    path = Path.join(tmp, name)
    File.write!(path, name)
    path
  end

  defp fake_timeout_bin(tmp, argv) do
    path = Path.join(tmp, "timeout")

    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$@" > "#{argv}"
    if [ "$1" = '--kill-after=5s' ]; then shift; fi
    shift
    exec "$@"
    """)

    File.chmod!(path, 0o755)
    path
  end
end
