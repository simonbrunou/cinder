defmodule Cinder.Subtitles.Sync.FfsubsyncTest do
  use ExUnit.Case, async: false

  alias Cinder.Subtitles.Sync.Ffsubsync

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

    timeout_args = File.read!(timeout_argv) |> String.split("\n", trim: true)
    assert Enum.at(timeout_args, 0) == "--kill-after=5s"
    assert Enum.at(timeout_args, 1) == "900"
    assert Enum.at(timeout_args, 2) == runner
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

      _ok_or_missing ->
        base
    end
    |> Jason.encode!()
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
