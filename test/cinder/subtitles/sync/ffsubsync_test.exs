defmodule Cinder.Subtitles.Sync.FfsubsyncTest do
  use ExUnit.Case, async: false

  alias Cinder.Subtitles.Sync.Ffsubsync

  setup do
    keys = [:ffsubsync_bin, :ffsubsync_python, :timeout_bin, Cinder.Subtitles.Sync.Ffsubsync]
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
    bin = fake_bin(tmp, argv, :ok)
    reference = Path.join(tmp, "reference with spaces.srt")
    input = Path.join(tmp, "input;touch-pwned.ass")
    output = Path.join(tmp, "output.ass")
    File.write!(reference, "reference")
    File.write!(input, "subtitle")
    Application.put_env(:cinder, :ffsubsync_bin, bin)
    Application.put_env(:cinder, :timeout_bin, fake_timeout_bin(tmp, timeout_argv))

    assert {:ok, %{offset_ms: 27_300, rate: 0.999, score: 42.5}} =
             Ffsubsync.sync(reference, input, output)

    args = File.read!(argv) |> String.split("\n", trim: true)
    assert args |> Enum.chunk_every(2, 1) |> Enum.any?(&(&1 == ["-i", input]))
    assert args |> Enum.chunk_every(2, 1) |> Enum.any?(&(&1 == ["-o", output]))
    assert "--skip-sync-on-low-quality" in args
    refute "--gss" in args
    assert "--min-score" in args

    assert Enum.chunk_every(args, 2, 1)
           |> Enum.any?(&(&1 == ["--max-offset-seconds", "90"]))

    assert Enum.chunk_every(args, 2, 1)
           |> Enum.any?(&(&1 == ["--quality-max-offset-seconds", "90"]))

    assert Path.extname(output) == Path.extname(input)
    assert File.read!(output) == "subtitle"
    refute File.exists?(Path.join(tmp, "pwned.ass"))

    timeout_args = File.read!(timeout_argv) |> String.split("\n", trim: true)
    assert Enum.at(timeout_args, 0) == "--kill-after=5s"
    assert Enum.at(timeout_args, 1) == "900"
    assert Enum.at(timeout_args, 2) == bin
  end

  @tag :tmp_dir
  test "passes explicit formats when anonymous paths have no extensions", %{tmp_dir: tmp} do
    argv = Path.join(tmp, "argv")
    bin = fake_bin(tmp, argv, :anonymous)
    reference = Path.join(tmp, "reference")
    input = Path.join(tmp, "input")
    output = Path.join(tmp, "output")
    File.write!(reference, "reference")
    File.write!(input, "subtitle")
    Application.put_env(:cinder, :ffsubsync_python, bin)

    Application.put_env(
      :cinder,
      :timeout_bin,
      fake_timeout_bin(tmp, Path.join(tmp, "timeout-argv"))
    )

    assert {:ok, %{score: 42.5}} = Ffsubsync.sync(reference, input, output, ".mkv", ".ass")
    args = File.read!(argv) |> String.split("\n", trim: true)
    assert args |> Enum.chunk_every(2, 1) |> Enum.any?(&(&1 == ["--cinder-input-format", "ass"]))
    assert args |> Enum.chunk_every(2, 1) |> Enum.any?(&(&1 == ["--cinder-output-format", "ass"]))

    assert args
           |> Enum.chunk_every(2, 1)
           |> Enum.any?(&(&1 == ["--cinder-reference-format", "mkv"]))
  end

  @tag :tmp_dir
  test "low confidence and missing output are review results", %{tmp_dir: tmp} do
    input = Path.join(tmp, "input.srt")
    reference = Path.join(tmp, "reference.srt")
    File.write!(input, "subtitle")
    File.write!(reference, "reference")

    Application.put_env(:cinder, :ffsubsync_bin, fake_bin(tmp, Path.join(tmp, "low"), :low))

    assert {:review, %{reason: :low_confidence}} =
             Ffsubsync.sync(reference, input, Path.join(tmp, "low-output.srt"))

    Application.put_env(
      :cinder,
      :ffsubsync_bin,
      fake_bin(tmp, Path.join(tmp, "missing"), :missing)
    )

    assert {:review, %{reason: :missing_output}} =
             Ffsubsync.sync(reference, input, Path.join(tmp, "missing-output.srt"))
  end

  @tag :tmp_dir
  test "an output with missing or below-threshold metrics fails closed", %{tmp_dir: tmp} do
    input = Path.join(tmp, "input.srt")
    reference = Path.join(tmp, "reference.srt")
    File.write!(input, "subtitle")
    File.write!(reference, "reference")

    Application.put_env(
      :cinder,
      :ffsubsync_bin,
      fake_bin(tmp, Path.join(tmp, "unparseable"), :unparseable)
    )

    assert {:review, %{reason: :unparseable_output}} =
             Ffsubsync.sync(reference, input, Path.join(tmp, "unparseable-output.srt"))

    Application.put_env(
      :cinder,
      :ffsubsync_bin,
      fake_bin(tmp, Path.join(tmp, "low-score"), :low_score)
    )

    assert {:review, %{reason: :low_confidence}} =
             Ffsubsync.sync(reference, input, Path.join(tmp, "low-score-output.srt"))
  end

  defp fake_bin(tmp, argv, mode) do
    path = Path.join(tmp, "ffsubsync-#{mode}")

    copy =
      if mode == :missing do
        ""
      else
        ~S'''
        input=''
        output=''
        previous=''
        for arg in "$@"; do
          if [ "$previous" = '-i' ]; then input="$arg"; fi
          if [ "$previous" = '-o' ]; then output="$arg"; fi
          previous="$arg"
        done
        cp "$input" "$output"
        '''
      end

    metrics =
      case mode do
        :unparseable ->
          "alignment complete\\n"

        :low_score ->
          "score: 9.500\\noffset seconds: 0.000\\nframerate scale factor: 1.000\\n"

        :low ->
          "score: 42.500\\noffset seconds: 27.300\\n" <>
            "framerate scale factor: 0.999\\nlow-quality alignment; leaving subtitles unmodified\\n"

        _ ->
          "score: 42.500\\noffset seconds: 27.300\\nframerate scale factor: 0.999\\n"
      end

    File.write!(
      path,
      "#!/bin/sh\nprintf '%s\\n' \"$@\" > #{argv}\n#{copy}\n" <>
        "printf '#{metrics}' >&2\n"
    )

    File.chmod!(path, 0o755)
    path
  end

  defp fake_timeout_bin(tmp, argv) do
    path = Path.join(tmp, "timeout")

    File.write!(
      path,
      "#!/bin/sh\nprintf '%s\\n' \"$@\" > #{argv}\n" <>
        "if [ \"$1\" = '--kill-after=5s' ]; then shift; fi\nshift\nexec \"$@\"\n"
    )

    File.chmod!(path, 0o755)
    path
  end
end
