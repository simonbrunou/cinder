defmodule Cinder.Test.PriorityShims do
  @moduledoc """
  Pins a `Cinder.LowPriority` command line, for `Cinder.Library.MediaInfo.FfprobeTest` "whole-file
  reads" and `Cinder.Subtitles.Sync.FfsubsyncTest` "priority".

  PATH holds only shims named `ionice` and `nice` that record their pid and arguments, then exec
  the real tool. The stub command `write_stub!/4` writes records the same, and the priority it
  runs at, read through the real tools by absolute path. That priority is relative to
  the suite's own, so the recorded command lines carry the exact checks
  (docs/agents/testing.md says why). A module using these replaces the process-global PATH, so
  it runs with `async: false`.
  """

  import ExUnit.Assertions, only: [flunk: 1]
  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  A setup callback. Resolves the real tools before a test replaces PATH, reads the priority this
  test process runs at, which a command started with no prefix inherits, and restores PATH on
  exit.
  """
  def real_priority_tools(_context) do
    tools =
      for name <- [:ionice, :nice, :sleep], into: %{} do
        {name, System.find_executable(to_string(name)) || flunk("these tests need #{name}")}
      end

    {niceness, 0} = System.cmd(tools.nice, [])
    niceness = niceness |> String.trim() |> String.to_integer()
    {class, 0} = System.cmd(tools.ionice, [])

    path = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", path) end)

    %{
      tools:
        Map.merge(tools, %{
          path: path,
          class: io_class(class),
          niceness: niceness,
          niced: min(niceness + 10, 19)
        })
    }
  end

  @doc """
  Sets PATH to hold only shims for the named tools. Each records its pid and arguments in
  `<tool>.log`, then execs the real tool in place.
  """
  def put_shims(tmp, tools, names) do
    File.mkdir_p!(Path.join(tmp, "bin"))

    for name <- names do
      File.write!(shim(tmp, name), """
      #!/bin/sh
      printf '%s\\n' "$$" "$@" > "#{Path.join(tmp, "#{name}.log")}"
      exec #{Map.fetch!(tools, name)} "$@"
      """)

      File.chmod!(shim(tmp, name), 0o755)
    end

    System.put_env("PATH", Path.join(tmp, "bin"))
  end

  def shim(tmp, name), do: Path.join([tmp, "bin", to_string(name)])

  @doc """
  Writes the stub command `<tmp>/<name>`. It records the priority it runs at for `priority/1` and
  its pid and arguments in `<name>.log`, then runs `script`. Returns its path.
  """
  def write_stub!(tmp, tools, name, script) do
    path = Path.join(tmp, name)

    File.write!(path, """
    #!/bin/sh
    echo "$(#{tools.nice}) $(#{tools.ionice})" > "#{Path.join(tmp, "priority")}"
    printf '%s\\n' "$$" "$@" > "#{Path.join(tmp, "#{name}.log")}"
    #{script}
    """)

    File.chmod!(path, 0o755)
    path
  end

  @doc "The lines a shim or stub wrote to `<name>.log`: its pid, then its arguments."
  def recorded(tmp, name),
    do: tmp |> Path.join("#{name}.log") |> File.read!() |> String.split("\n", trim: true)

  @doc "The I/O class and niceness the stub command recorded."
  def priority(tmp) do
    [niceness, class] =
      tmp |> Path.join("priority") |> File.read!() |> String.trim() |> String.split(" ", parts: 2)

    {io_class(class), String.to_integer(niceness)}
  end

  # `ionice` prints `idle`, or `none: prio 4` and the like, whose prio varies by kernel.
  defp io_class(output), do: output |> String.trim() |> String.split(":") |> hd()
end
