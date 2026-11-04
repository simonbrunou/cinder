defmodule Cinder.CodeHealth.MountPathRawReadsTest do
  # Every plain `File` call queues behind the VM's one file server (`:file_server_2`), so a read
  # hung on a wedged mount there blocks every `File` call in the app until the mount answers.
  # #779 and #944 moved the walks off it; #1114 moved the single-path reads of these modules,
  # which read paths under an import or library root or the `/proc/<pid>/fd/<n>` descriptor path
  # of a file there. `Cinder.Library.Filesystem.DiskFileServerTest` covers the reads a public
  # entry point reaches with the file server suspended. This fence covers the rest: a read below
  # passes `:raw` in a literal option list, or lists a directory through `Disk.ls/1`. Writes are
  # out of scope (#1114).
  use ExUnit.Case, async: true

  @modules [
    "lib/cinder/download/path_mapping.ex",
    "lib/cinder/library/book_archive/rar.ex",
    "lib/cinder/library/book_archive/zip.ex",
    "lib/cinder/library/filesystem/disk.ex",
    "lib/cinder/subtitles/sidecar_transaction/atomic_file.ex",
    "lib/cinder/subtitles/sidecar_transaction/backup.ex",
    "lib/cinder/subtitles/sync.ex"
  ]

  # `File.ls/1`, `File.ls!/1` and `:file.list_dir/1` take no `:raw`, so every call fails.
  @file_reads [:stat, :stat!, :lstat, :lstat!, :ls, :ls!, :read, :read!, :open, :open!] ++
                [:exists?, :dir?, :regular?]
  @erlang_reads [:read_file_info, :read_link_info, :list_dir, :read_file, :open]

  test "the mount-path modules read every path with :raw" do
    assert Enum.reject(@modules, &File.exists?/1) == [],
           "A module this fence scans moved or was renamed: update @modules."

    found =
      for path <- @modules,
          line <- path |> File.read!() |> non_raw_read_lines(),
          do: "#{path}:#{line}"

    assert found == [],
           "These reads go through the VM's one file server, which a wedged mount blocks for " <>
             "every File call in the app:\n" <>
             Enum.join(found, "\n") <>
             "\nPass :raw in a literal option list (File.stat(path, [:raw]), " <>
             "File.read(path, [:raw]), File.open(path, [:raw | modes])), or list a directory " <>
             "with Cinder.Library.Filesystem.Disk.ls/1 (#1114)."
  end

  test "the scan flags each non-raw read form and passes raw reads, writes, comments and strings" do
    source = ~S'''
    defmodule M do
      def a(p), do: File.stat(p)
      def b(p), do: File.lstat(p)
      def c(p), do: File.ls(p)
      def d(p), do: File.read(p)
      def e(p), do: File.open(p, [:read, :binary])
      def f(p), do: File.read!(p)
      def g(p), do: File.exists?(p)
      def h(p), do: :file.read_file_info(p)
      def i(p), do: :file.read_link_info(p, time: :universal)
      def j(p), do: :file.list_dir(p)
      def k(p), do: :file.read_file(p)
      def l(p), do: :file.open(p, [:read])
      def m(p, modes), do: File.open(p, modes)
      def n(p), do: Enum.map([p], &File.read/1)
      def o(p), do: p |> File.stat()
      def q(p, opts), do: File.stat(p, opts ++ [:raw])
      def r(p),
        do:
          File.stat(
            p
          )

      def s(p), do: File.stat(p, [:raw])
      def t(p), do: File.lstat(p, [:raw])
      def u(p), do: File.read(p, [:raw])
      def v(p, modes), do: File.open(p, [:raw | modes])
      def w(p), do: File.open(p, [:read, :raw, :binary])
      def x(p), do: p |> File.stat([:raw])
      def y(p), do: Enum.map([p], &File.read(&1, [:raw]))
      def z(p), do: :file.read_link_info(p, [:raw, time: :universal])
      def aa(p), do: :file.open(p, [:read, :binary, :raw])
      def ab(p), do: :prim_file.list_dir(p)
      def ac(p), do: File.write(p, "x")
      def ad(p), do: SafeFile.read(p)
      def ae(info), do: File.Stat.from_record(info)
      # File.stat(p)
      @doc "File.read(p)"
      def af, do: "File.ls(p)"
    end
    '''

    # Lines 2 to 17 hold one non-raw form each, and line 20 opens the call split across lines.
    assert non_raw_read_lines(source) == Enum.to_list(2..17) ++ [20]
  end

  # The lines of the calls in the parsed source that read a path without a literal `:raw`
  # option. A comment and a string's contents are not code, so they never match.
  defp non_raw_read_lines(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_ast, lines} =
      Macro.prewalk(ast, [], fn node, lines ->
        if non_raw_read?(node), do: {node, [line(node) | lines]}, else: {node, lines}
      end)

    Enum.sort(lines)
  end

  defp non_raw_read?({{:., _, [{:__aliases__, _, [:File]}, name]}, _meta, args})
       when name in @file_reads,
       do: not raw_option?(args)

  defp non_raw_read?({{:., _, [:file, name]}, _meta, args}) when name in @erlang_reads,
    do: not raw_option?(args)

  defp non_raw_read?(_node), do: false

  # A literal list among the arguments holds `:raw`, as an element or as the head of a
  # `[:raw | modes]` cons. A variable or a computed list proves nothing.
  defp raw_option?(args), do: Enum.any?(args, &raw_list?/1)

  defp raw_list?(list) when is_list(list), do: Enum.any?(list, &raw_element?/1)
  defp raw_list?(_arg), do: false

  defp raw_element?(:raw), do: true
  defp raw_element?({:|, _, [head, _tail]}), do: raw_element?(head)
  defp raw_element?(_element), do: false

  defp line({_call, meta, _args}), do: Keyword.get(meta, :line)
end
