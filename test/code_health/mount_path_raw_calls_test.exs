defmodule Cinder.CodeHealth.MountPathRawCallsTest do
  # Every plain `File` call queues behind the VM's one file server (`:file_server_2`), so a call
  # hung on a wedged mount there blocks every `File` call in the app until the mount answers.
  # #779 and #944 moved the walks off it, #1114 the single-path reads and #1146 the writes and
  # other changes these modules make to paths under an import or library root, or to the
  # `/proc/<pid>/fd/<n>` descriptor path of a file there. `Cinder.Library.Filesystem.
  # DiskFileServerTest` covers the calls a public entry point reaches with the file server
  # suspended. This fence covers the rest and every new call: a read, a `File.write` or
  # `write_stat` and a `:file` write pass `:raw` in a literal option list, a directory listing
  # goes through `Disk.ls/1`, and any other change goes through `Cinder.RawFile` or `:prim_file`.
  # It does not flag `System.find_executable/1`: the lookups left in these modules read `PATH` on
  # local disk, and `Cinder.BoundedCommandLookupTest` covers the one before each subprocess `Disk`
  # starts.
  use ExUnit.Case, async: true

  @modules [
    "lib/cinder/bounded_command.ex",
    "lib/cinder/download/path_mapping.ex",
    "lib/cinder/library/book_archive.ex",
    "lib/cinder/library/filesystem.ex",
    "lib/cinder/raw_file.ex",
    "lib/cinder/subtitles/sidecar_transaction.ex",
    "lib/cinder/subtitles/sync.ex"
  ]

  # Every module in these directories works on import, library or descriptor paths, so the fence
  # scans each one, a module split out of another included: #1196 split `Bound` and `Workspace`
  # out of `AtomicFile`, and the fence missed them until #1197 listed them.
  @module_dirs [
    "lib/cinder/library/book_archive",
    "lib/cinder/library/filesystem",
    "lib/cinder/subtitles/sidecar_transaction"
  ]

  # Modules the directories above must still hold: a move out of them would drop the module from
  # the scan with no failure.
  @dir_modules [
    "lib/cinder/library/filesystem/disk.ex",
    "lib/cinder/subtitles/sidecar_transaction/bound.ex",
    "lib/cinder/subtitles/sidecar_transaction/workspace.ex"
  ]

  # `File.ls/1`, `File.ls!/1` and `:file.list_dir/1` take no `:raw`, so every call fails.
  @file_reads [:stat, :stat!, :lstat, :lstat!, :ls, :ls!, :read, :read!, :open, :open!] ++
                [:exists?, :dir?, :regular?]
  @file_writes [:write, :write!, :write_stat, :write_stat!]
  # These take no `:raw` option, so every call fails, an option list or not.
  @file_server_only [:chmod, :chmod!, :mkdir, :mkdir!, :mkdir_p, :mkdir_p!, :rm, :rm!] ++
                      [:rmdir, :rmdir!, :rm_rf, :rm_rf!, :ln, :ln!, :ln_s, :ln_s!, :cp, :cp!] ++
                      [:cp_r, :cp_r!, :rename, :rename!, :touch, :touch!]
  @erlang_reads [:read_file_info, :read_link_info, :list_dir, :read_file, :open]
  @erlang_writes [:write_file, :change_mode, :make_dir, :delete, :del_dir, :rename] ++
                   [:make_link, :write_file_info]

  @file_raw_calls @file_reads ++ @file_writes
  @erlang_raw_calls @erlang_reads ++ @erlang_writes

  test "the mount-path modules call the filesystem with :raw" do
    assert Enum.reject(@modules ++ @module_dirs, &File.exists?/1) == [],
           "A module or directory this fence scans moved or was renamed: update @modules or " <>
             "@module_dirs."

    paths = fence_paths()

    assert @dir_modules -- paths == [],
           "A module this fence scans through @module_dirs moved: update @module_dirs or " <>
             "@dir_modules."

    found =
      for path <- paths,
          line <- path |> File.read!() |> file_server_call_lines(),
          do: "#{path}:#{line}"

    assert found == [],
           "These calls go through the VM's one file server, which a wedged mount blocks for " <>
             "every File call in the app:\n" <>
             Enum.join(found, "\n") <>
             "\nPass :raw in a literal option list (File.stat(path, [:raw]), " <>
             "File.read(path, [:raw]), File.open(path, [:raw | modes]), " <>
             "File.write(path, content, [:raw])), list a directory with " <>
             "Cinder.Library.Filesystem.Disk.ls/1, or change the filesystem through " <>
             "Cinder.RawFile (#1114, #1146)."
  end

  @tag :tmp_dir
  test "the scan picks each listed module and every .ex module below each listed directory",
       %{tmp_dir: tmp} do
    for path <- ["listed.ex", "dir/split_out.ex", "dir/nested/deeper.ex", "dir/notes.md"] do
      File.mkdir_p!(Path.dirname(Path.join(tmp, path)))
      File.write!(Path.join(tmp, path), "")
    end

    scanned = scanned_paths([Path.join(tmp, "listed.ex")], [Path.join(tmp, "dir")])

    assert Enum.map(scanned, &Path.relative_to(&1, tmp)) ==
             ["dir/nested/deeper.ex", "dir/split_out.ex", "listed.ex"]
  end

  test "the scan flags each non-raw read form and passes raw reads, raw writes, comments and " <>
         "strings" do
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
      def ac(p), do: File.write(p, "x", [:raw])
      def ad(p), do: SafeFile.read(p)
      def ae(info), do: File.Stat.from_record(info)
      # File.stat(p)
      @doc "File.read(p)"
      def af, do: "File.ls(p)"
    end
    '''

    # Lines 2 to 17 hold one non-raw form each, and line 20 opens the call split across lines.
    assert file_server_call_lines(source) == Enum.to_list(2..17) ++ [20]
  end

  test "the scan flags each write form that skips :raw and passes raw writes, comments and " <>
         "strings" do
    source = ~S'''
    defmodule M do
      def a(p), do: File.write(p, "x")
      def b(p), do: File.write!(p, "x")
      def c(p, s), do: File.write_stat(p, s)
      def d(p, s), do: File.write_stat!(p, s)
      def e(p), do: File.chmod(p, 0o644)
      def f(p), do: File.chmod!(p, 0o644)
      def g(p), do: File.mkdir(p)
      def h(p), do: File.mkdir!(p)
      def i(p), do: File.mkdir_p(p)
      def j(p), do: File.mkdir_p!(p)
      def k(p), do: File.rm(p)
      def l(p), do: File.rm!(p)
      def m(p), do: File.rmdir(p)
      def n(p), do: File.rmdir!(p)
      def o(p), do: File.rm_rf(p)
      def q(p), do: File.rm_rf!(p)
      def r(a, b), do: File.ln(a, b)
      def s(a, b), do: File.ln!(a, b)
      def t(a, b), do: File.ln_s(a, b)
      def u(a, b), do: File.ln_s!(a, b)
      def v(a, b), do: File.cp(a, b)
      def w(a, b), do: File.cp!(a, b)
      def x(a, b), do: File.cp_r(a, b)
      def y(a, b), do: File.cp_r!(a, b)
      def z(a, b), do: File.rename(a, b)
      def aa(a, b), do: File.rename!(a, b)
      def ab(p), do: File.touch(p)
      def ac(p), do: File.touch!(p)
      def ad(p), do: :file.write_file(p, "x")
      def ae(p), do: :file.change_mode(p, 0o644)
      def af(p), do: :file.make_dir(p)
      def ag(p), do: :file.delete(p)
      def ah(p), do: :file.del_dir(p)
      def ai(a, b), do: :file.rename(a, b)
      def aj(a, b), do: :file.make_link(a, b)
      def ak(p, info), do: :file.write_file_info(p, info)
      def al(p, modes), do: File.write(p, "x", modes)
      def am(p), do: File.rm(p, [:raw])
      def an(p), do: Enum.each([p], &File.rm/1)
      def ao(p), do: p |> File.rm_rf()
      def ap(p),
        do:
          File.mkdir_p(
            p
          )

      def aq(p), do: File.write(p, "x", [:raw])
      def ar(p), do: File.write!(p, "x", [:append, :raw])
      def as(p, s), do: File.write_stat(p, s, [:raw])
      def at(p, s), do: File.write_stat!(p, s, [:raw, time: :posix])
      def au(p), do: :file.write_file(p, "x", [:raw])
      def av(p), do: :file.delete(p, [:raw])
      def aw(p, info), do: :file.write_file_info(p, info, [:raw])
      def ax(p), do: :prim_file.make_dir(p)
      def ay(p), do: :prim_file.delete(p)
      def az(p), do: :prim_file.del_dir(p)
      def ba(a, b), do: :prim_file.rename(a, b)
      def bb(a, b), do: :prim_file.make_link(a, b)
      def bc(p), do: RawFile.mkdir_p(p)
      def bd(name), do: System.find_executable(name)
      # File.rm(p)
      @doc "File.chmod(p, 0o644)"
      def be, do: "File.write(p, x)"
    end
    '''

    # Lines 2 to 41 hold one form each that skips `:raw` (line 39 passes one to a call that takes
    # none), and line 44 opens the call split across lines.
    assert file_server_call_lines(source) == Enum.to_list(2..41) ++ [44]
  end

  defp fence_paths, do: scanned_paths(@modules, @module_dirs)

  defp scanned_paths(modules, dirs) do
    Enum.sort(modules ++ Enum.flat_map(dirs, &Path.wildcard(Path.join(&1, "**/*.ex"))))
  end

  # The lines of the calls in the parsed source that reach the file server: a read or write
  # without a literal `:raw` option, or a change that takes none. A comment and a string's
  # contents are not code, so they never match.
  defp file_server_call_lines(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_ast, lines} =
      Macro.prewalk(ast, [], fn node, lines ->
        if file_server_call?(node), do: {node, [line(node) | lines]}, else: {node, lines}
      end)

    Enum.sort(lines)
  end

  defp file_server_call?({{:., _, [{:__aliases__, _, [:File]}, name]}, _meta, args})
       when name in @file_raw_calls,
       do: not raw_option?(args)

  defp file_server_call?({{:., _, [{:__aliases__, _, [:File]}, name]}, _meta, _args})
       when name in @file_server_only,
       do: true

  defp file_server_call?({{:., _, [:file, name]}, _meta, args}) when name in @erlang_raw_calls,
    do: not raw_option?(args)

  defp file_server_call?(_node), do: false

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
