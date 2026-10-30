defmodule Cinder.CodeHealth.RawSpawnTest do
  # `start_supervised!/1` stops its child before the test's `on_exit` callbacks run
  # (`ExUnit.Callbacks`), and deps/phoenix/usage-rules/elixir.md ("Test guidelines") starts every
  # process a test needs with it. Nothing stops a child of `spawn/1`, `spawn_monitor/1` or an
  # unlinked `Task.start/1`, `Agent.start/1` or `GenServer.start/2`, so it can run on into the
  # next test. A `spawn_link/1` child only gets the test process's exit signal, which arrives
  # asynchronously and which it survives if it traps exits. #1008's regression test started its
  # caller with `spawn_monitor/1`, and the review sent it back for a fix round. The files in
  # `@allowed` started processes these ways before this fence: each keeps exactly that many, and
  # every other file under test/ starts none.
  use ExUnit.Case, async: true

  @allowed %{
    "test/cinder/download/intent_test.exs" => 9,
    "test/cinder/library/staged_import_test.exs" => 2,
    "test/cinder/requests_test.exs" => 1,
    "test/cinder/subtitles/sidecar_transaction_test.exs" => 1
  }

  @spawns [:spawn, :spawn_link, :spawn_monitor]
  @unlinked_starters [:Task, :Agent, :GenServer]
  @definitions [:def, :defp, :defmacro, :defmacrop]

  test "no test file makes more raw spawns or unlinked starts than its ceiling" do
    over =
      for path <- Path.wildcard("test/**/*.{ex,exs}"),
          lines = path |> File.read!() |> start_lines(),
          length(lines) > Map.get(@allowed, path, 0),
          do: "#{path}: lines #{Enum.join(lines, ", ")}, at most #{Map.get(@allowed, path, 0)}"

    assert over == [],
           "These files start processes outside the test supervisor more often than allowed:\n" <>
             Enum.join(over, "\n") <>
             "\nStart each with start_supervised!/2, for example " <>
             "start_supervised!({Task, fun}, id: make_ref()) (deps/phoenix/usage-rules/elixir.md)."
  end

  test "each @allowed ceiling is its file's count today" do
    stale =
      for {path, ceiling} <- @allowed,
          count =
            if(File.exists?(path), do: path |> File.read!() |> start_lines() |> length(), else: 0),
          count != ceiling,
          do: "#{path}: #{count}, ceiling #{ceiling}"

    assert stale == [],
           "Set each ceiling in @allowed to its file's count, and drop an entry at 0:\n" <>
             Enum.join(stale, "\n")
  end

  test "the count matches each start form and skips definitions, specs and strings" do
    source = ~S'''
    defmodule M do
      def a, do: spawn(fn -> :ok end)
      def b, do: spawn_link(fn -> :ok end)
      def c, do: spawn_monitor(fn -> :ok end)
      def d, do: Process.spawn(fn -> :ok end, [:monitor])
      def e, do: Kernel.spawn_monitor(fn -> :ok end)
      def f, do: :erlang.spawn(fn -> :ok end)
      def g, do: Enum.map([fn -> :ok end], &spawn/1)
      def h, do: Task.start(fn -> :ok end)
      def i, do: Agent.start(fn -> :ok end)
      def j, do: GenServer.start(M, :ok)
      def o(pid \\ spawn(fn -> :ok end)), do: pid

      @spec spawn(fun()) :: pid()
      defp spawn(fun) when is_function(fun), do: fun

      @doc """
      spawn(fn -> :ok end)
      """
      def k, do: start_supervised!({Task, fn -> :ok end})
      def l, do: Task.start_link(fn -> :ok end)
      def m, do: Task.async(fn -> :ok end)
      def n(spawn), do: spawn
    end
    '''

    assert start_lines(source) == Enum.to_list(2..12)
  end

  # The lines of the spawn calls and unlinked starts in the parsed source. A string's contents are
  # not code, and a definition's name or a `@spec` names a function without calling it. The
  # definition keeps its arguments, so a `\\` default that spawns still counts.
  defp start_lines(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_ast, lines} =
      Macro.prewalk(ast, [], fn
        {kind, meta, [head | body]}, lines when kind in @definitions ->
          {{kind, meta, [unnamed(head) | body]}, lines}

        # An atom has no children, so the walk skips everything the attribute held.
        {:@, _, [{attribute, _, _}]}, lines when attribute in [:spec, :callback] ->
          {:spec_skipped, lines}

        node, lines ->
          if start?(node), do: {node, [line(node) | lines]}, else: {node, lines}
      end)

    Enum.sort(lines)
  end

  defp unnamed({:when, meta, [call | guards]}), do: {:when, meta, [unnamed(call) | guards]}
  defp unnamed({_name, meta, args}), do: {:definition_name, meta, args}
  defp unnamed(head), do: head

  defp start?({name, _meta, args}) when name in @spawns and is_list(args), do: true

  defp start?({:&, _meta, [{:/, _, [{name, _, context}, _arity]}]})
       when name in @spawns and is_atom(context),
       do: true

  defp start?({{:., _, [{:__aliases__, _, [module]}, name]}, _meta, _args})
       when module in [:Kernel, :Process] and name in @spawns,
       do: true

  defp start?({{:., _, [{:__aliases__, _, [module]}, :start]}, _meta, _args})
       when module in @unlinked_starters,
       do: true

  defp start?({{:., _, [:erlang, name]}, _meta, _args}) when name in @spawns, do: true
  defp start?(_node), do: false

  defp line({_name, meta, _args}), do: Keyword.get(meta, :line)
end
