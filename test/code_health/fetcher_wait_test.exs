defmodule Cinder.CodeHealth.FetcherWaitTest do
  # A test waits on the shared `Cinder.Subtitles.Fetcher` only through
  # `Cinder.LibraryStubs.await_subtitle_tasks/0`, which waits past the test-env Disk bound. A
  # direct `:sys.get_state/1` gives up after its 5 s default, and on CI run 2922 that timeout
  # failed `Cinder.Library.KeptFileSidecarsTest` while a fetch was still writing its manifest
  # through a Disk subprocess (#1028). The walk sees a `:sys` wait whose target is the Fetcher's
  # alias, its atom or `Process.whereis/1` of it, called or piped into.
  use ExUnit.Case, async: true

  @helper "test/support/library_stubs.ex"
  @waits [:get_state, :get_status]

  test "only LibraryStubs waits on the subtitle Fetcher with :sys" do
    direct =
      for path <- Path.wildcard("test/**/*.{ex,exs}"),
          path != @helper,
          line <- path |> File.read!() |> wait_lines(),
          do: "#{path}:#{line}"

    assert direct == [],
           "These tests wait on Cinder.Subtitles.Fetcher with :sys directly, whose 5 s default " <>
             "falls below the test-env Disk bound:\n" <>
             Enum.join(direct, "\n") <>
             "\nCall Cinder.LibraryStubs.await_subtitle_tasks/0 instead (docs/agents/testing.md)."
  end

  test "the helper itself still waits on the Fetcher with :sys" do
    assert @helper |> File.read!() |> wait_lines() != []
  end

  test "the walk finds each wait form on the Fetcher and skips other targets, comments and strings" do
    source = ~S'''
    defmodule M do
      alias Cinder.Subtitles.Fetcher

      def a, do: :sys.get_state(Cinder.Subtitles.Fetcher)
      def b, do: :sys.get_state(Cinder.Subtitles.Fetcher, 5_000)
      def c, do: :sys.get_state(Fetcher)
      def d, do: Cinder.Subtitles.Fetcher |> :sys.get_state()
      def e, do: Fetcher |> :sys.get_state(5_000)
      def f, do: :sys.get_state(Process.whereis(Cinder.Subtitles.Fetcher))
      def g, do: :sys.get_status(Fetcher)
      def h, do: :sys.get_state(:"Elixir.Cinder.Subtitles.Fetcher")
      def i(view), do: :sys.get_state(view.pid)
      def j, do: :sys.get_state(Cinder.Library.BoundedWalk)
      def k, do: Cinder.LibraryStubs.await_subtitle_tasks()

      @doc """
      :sys.get_state(Cinder.Subtitles.Fetcher)
      """
      def l, do: :ok

      def m do
        :sys.get_state(
          Cinder.Subtitles.Fetcher
        )
      end

      def n do
        Fetcher
        |> :sys.get_state()
      end

      # :sys.get_state(Cinder.Subtitles.Fetcher)
      def o, do: :ok
    end
    '''

    assert wait_lines(source) == Enum.to_list(4..11) ++ [22, 29]
  end

  # The lines of the `:sys` waits on the Fetcher in the parsed source. A string's contents are
  # not code. A piped wait is counted at the pipe, and its inner call has no Fetcher argument.
  defp wait_lines(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_ast, lines} =
      Macro.prewalk(ast, [], fn
        {:|>, meta, [target, {{:., _, [:sys, name]}, _, _args}]} = node, lines
        when name in @waits ->
          {node, add_if_fetcher(lines, target, meta)}

        {{:., _, [:sys, name]}, meta, [target | _args]} = node, lines when name in @waits ->
          {node, add_if_fetcher(lines, target, meta)}

        node, lines ->
          {node, lines}
      end)

    Enum.sort(lines)
  end

  defp add_if_fetcher(lines, target, meta),
    do: if(fetcher?(target), do: [Keyword.get(meta, :line) | lines], else: lines)

  defp fetcher?({:__aliases__, _, segments}), do: List.last(segments) == :Fetcher
  defp fetcher?(Cinder.Subtitles.Fetcher), do: true

  defp fetcher?({{:., _, [{:__aliases__, _, [:Process]}, :whereis]}, _, [target]}),
    do: fetcher?(target)

  defp fetcher?(_target), do: false
end
