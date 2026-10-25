defmodule Cinder.Test.FakeUnrar do
  @moduledoc """
  A fake `unrar` binary for the tests that drive `Cinder.Library.BookArchive.Rar`.

  `unrar` is closed-source and cannot be scripted to produce a controlled fixture, so a test puts
  a shell script named `unrar` at the front of `PATH`, the seam `System.find_executable/1`
  resolves through. `PATH` is OS-process-wide, so every caller runs `async: false`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  A setup callback (`setup {Cinder.Test.FakeUnrar, :fakebin}`): an empty `fakebin` directory
  under the test's `tmp_dir`, and the `original_path` that `PATH` is restored to on exit.
  """
  def fakebin(%{tmp_dir: tmp}) do
    original_path = System.get_env("PATH")
    fakebin = Path.join(tmp, "fakebin")
    File.mkdir_p!(fakebin)

    on_exit(fn ->
      if original_path, do: System.put_env("PATH", original_path), else: System.delete_env("PATH")
    end)

    {:ok, %{fakebin: fakebin, original_path: original_path}}
  end

  @doc """
  Installs `script` as the `unrar` resolved by `System.find_executable/1` for the rest of the
  calling test, by putting `fakebin` ahead of `original_path`.
  """
  def install(fakebin, original_path, script) do
    path = Path.join(fakebin, "unrar")
    File.write!(path, script)
    File.chmod!(path, 0o755)
    System.put_env("PATH", fakebin <> ":" <> (original_path || ""))
  end

  @doc """
  A script that lists one entry, `name` (a plain file name: no quote, `$` or backtick), and
  "extracts" it by copying `bytes` into the destination, so the resolver's magic-byte gate still
  runs on what the archive held.

  The fixture sits beside the script and is found through `$0`, so a `tmp_dir` path holding a
  quote (ExUnit names it after the test) never reaches the script's text.
  """
  def extracting(fakebin, name, bytes) do
    fixture = "fixture" <> Path.extname(name)
    File.write!(Path.join(fakebin, fixture), bytes)

    """
    #!/bin/sh
    case "$1" in
      lb) printf '%s\\n' '#{name}'; exit 0 ;;
      x) cp "${0%/*}/#{fixture}" "$7#{name}"; exit 0 ;;
    esac
    """
  end
end
