defmodule Cinder.CodeHealth.NestedCaseTest do
  # deps/usage_rules/usage-rules/elixir.md: "Avoid nested `case` statements - refactor to a single
  # `case`, `with` or separate functions." Credo's nesting depth allows a `case` inside another
  # `case`'s clause, so only a review caught one. On #1268 the Standards review sent such a `case`
  # back after the full suite had passed, and the fix needed a second full suite: about 11 minutes.
  #
  # A nested `case` is one that sits in a clause of another `case`, at any depth, with no
  # anonymous function between them: an `if`, `with`, `cond`, `receive` or `try` in between does
  # not end the nesting, and an `fn` or a `&` capture does, as a separate function would. The
  # files in `@allowed` held nested `case`s before this fence: each keeps exactly that many, and
  # every other file under lib/ holds none.
  #
  # Forms the walk does not follow include: a `case` in the subject of a `case` that sits in no
  # other `case`'s clause (`case (case x do ... end) do`), a `case` written as
  # `Kernel.SpecialForms.case/2`, a `case` that a macro call expands to, since the walk reads the
  # source before expansion, and a `case` in a HEEx template (a `~H` sigil, which the walk reads
  # as a string, or a `.heex` file, which it does not read). The first two and the last occur
  # nowhere under lib/ today.
  use ExUnit.Case, async: true

  @allowed %{
    "lib/cinder/acquisition/anime_parser.ex" => 1,
    "lib/cinder/books/identity.ex" => 1,
    "lib/cinder/catalog/grabs.ex" => 1,
    "lib/cinder/catalog/metadata_refresh.ex" => 1,
    "lib/cinder/catalog/movie_catalog.ex" => 1,
    "lib/cinder/catalog/scene_numbering.ex" => 1,
    "lib/cinder/catalog/series_catalog.ex" => 1,
    "lib/cinder/catalog/tmdb/http.ex" => 2,
    "lib/cinder/catalog/upgrade_hunter.ex" => 1,
    "lib/cinder/database_backup.ex" => 1,
    "lib/cinder/disk.ex" => 2,
    "lib/cinder/download.ex" => 1,
    "lib/cinder/download/client/qbittorrent.ex" => 2,
    "lib/cinder/download/client/sabnzbd.ex" => 7,
    "lib/cinder/download/orphan_folders.ex" => 1,
    "lib/cinder/download/torrent.ex" => 1,
    "lib/cinder/download/tv_poller.ex" => 1,
    "lib/cinder/http_policy/pinned_adapter.ex" => 2,
    "lib/cinder/library/adoption.ex" => 1,
    "lib/cinder/library/audiobook_sources.ex" => 1,
    "lib/cinder/library/filesystem/disk.ex" => 5,
    "lib/cinder/library/media_server/reconciler.ex" => 1,
    "lib/cinder/library/migration_adoption.ex" => 3,
    "lib/cinder/library/migration_source/sonarr.ex" => 1,
    "lib/cinder/library/sidecars.ex" => 1,
    "lib/cinder/requests.ex" => 1,
    "lib/cinder/settings.ex" => 1,
    "lib/cinder/subtitles.ex" => 4,
    "lib/cinder/subtitles/shot_changes.ex" => 1,
    "lib/cinder/subtitles/sidecar_transaction/atomic_file.ex" => 1,
    "lib/cinder/subtitles/sidecar_transaction/backup.ex" => 1,
    "lib/cinder/subtitles/sidecar_transaction/recovery.ex" => 1,
    "lib/cinder/subtitles/sync.ex" => 2,
    "lib/cinder/subtitles/sync/engine_workspace.ex" => 1,
    "lib/cinder/subtitles/sync/timing.ex" => 1,
    "lib/cinder_web/controllers/api_controller.ex" => 1,
    "lib/cinder_web/live/dashboard_live.ex" => 1,
    "lib/cinder_web/live/library_live.ex" => 2,
    "lib/cinder_web/live/my_requests_live.ex" => 1,
    "lib/cinder_web/live/profiles_live.ex" => 1,
    "lib/cinder_web/live/requests_live.ex" => 1,
    "lib/cinder_web/live/users_live.ex" => 1
  }

  test "no lib/ file nests more case expressions than its ceiling" do
    over = over(lib_counts(), @allowed)

    assert over == [],
           "These files nest a case in another case's clause more often than allowed:\n" <>
             Enum.join(over, "\n") <>
             "\nRefactor to a single case, a with, or a separate function " <>
             "(deps/usage_rules/usage-rules/elixir.md)."
  end

  test "each @allowed ceiling is its file's count today" do
    stale = stale(lib_counts(), @allowed)

    assert stale == [],
           "Set each ceiling in @allowed to its file's count, and drop an entry at 0:\n" <>
             Enum.join(stale, "\n")
  end

  test "a file over its ceiling, or with no entry, is reported with its lines" do
    counts = %{"lib/a.ex" => [3, 9], "lib/b.ex" => [4], "lib/c.ex" => [7]}
    allowed = %{"lib/a.ex" => 1, "lib/c.ex" => 1}

    assert over(counts, allowed) == [
             "lib/a.ex: lines 3, 9, at most 1",
             "lib/b.ex: lines 4, at most 0"
           ]
  end

  test "a ceiling above its file's count, or for a file with none, is stale" do
    counts = %{"lib/a.ex" => [3]}
    allowed = %{"lib/a.ex" => 2, "lib/gone.ex" => 1}

    assert stale(counts, allowed) == ["lib/a.ex: 1, ceiling 2", "lib/gone.ex: 0, ceiling 1"]
  end

  test "the walk counts a case in a clause of another case, in each form it reads" do
    source = ~S'''
    defmodule M do
      def direct(x) do
        case x do
          {:ok, y} ->
            case y do
              1 -> :one
              _ -> :other
            end
        end
      end

      def piped_inner(x) do
        case x do
          {:ok, y} -> y |> case do
            1 -> :one
          end
        end
      end

      def piped_outer(x) do
        x
        |> case do
          {:ok, y} ->
            case y do
              1 -> :one
            end
        end
      end

      def keyword_form(x), do: case(x, do: ({:ok, y} -> case(y, do: (1 -> :one))))

      def through_other_forms(x) do
        case x do
          {:ok, y} ->
            if y do
              with {:ok, z} <- y do
                cond do
                  z ->
                    receive do
                      _ ->
                        try do
                          case z do
                            1 -> :one
                          end
                        rescue
                          _ -> :error
                        end
                    end
                end
              end
            end
        end
      end

      def three_deep(x) do
        case x do
          {:ok, y} ->
            case y do
              {:ok, z} ->
                case z do
                  1 -> :one
                end
            end
        end
      end

      def in_inner_subject(x) do
        case x do
          {:ok, y} -> case(case y do 1 -> :one end, do: (_ -> :other))
        end
      end
    end
    '''

    assert nested_lines(source) == [5, 14, 24, 30, 42, 58, 60, 69, 69]
  end

  test "the walk skips a case behind an fn or a capture, a sibling case, and a case in text" do
    source = ~S'''
    defmodule M do
      def behind_fn(x) do
        case x do
          {:ok, list} ->
            Enum.map(list, fn y ->
              case y do
                1 -> :one
              end
            end)
        end
      end

      def behind_capture(x) do
        case x do
          {:ok, list} -> Enum.map(list, &case(&1, do: (1 -> :one)))
        end
      end

      def in_comment(x) do
        case x do
          # {:ok, y} -> case y do 1 -> :one end
          _ -> :other
        end
      end

      def siblings(x) do
        case x do
          1 -> :one
        end

        case x do
          2 -> :two
        end
      end

      def separate(x) do
        case x do
          {:ok, y} -> helper(y)
        end
      end

      defp helper(y) do
        case y do
          1 -> :one
        end
      end

      @doc """
      case x do
        _ -> case y do _ -> :z end
      end
      """
      def in_string, do: :ok
    end
    '''

    assert nested_lines(source) == []
  end

  # The forms the header names as not followed.
  test "the walk misses each form the header names" do
    source = ~S'''
    defmodule M do
      def in_subject(x) do
        case (case x do 1 -> :one end) do
          :one -> :ok
        end
      end

      def remote(x) do
        case x do
          {:ok, y} -> Kernel.SpecialForms.case(y, do: (1 -> :one))
        end
      end

      defmacrop one?(y), do: quote(do: case(unquote(y), do: (1 -> true)))

      def macro_call(x) do
        case x do
          {:ok, y} -> one?(y)
        end
      end

      def heex(assigns) do
        case assigns do
          %{y: _} -> ~H"<%= case @y do %><% 1 -> %>one<% end %>"
        end
      end
    end
    '''

    assert nested_lines(source) == []
  end

  defp lib_counts do
    for path <- Path.wildcard("lib/**/*.{ex,exs}"),
        lines = path |> File.read!() |> nested_lines(),
        lines != [],
        into: %{},
        do: {path, lines}
  end

  defp over(counts, allowed) do
    for {path, lines} <- Enum.sort(counts),
        length(lines) > Map.get(allowed, path, 0),
        do: "#{path}: lines #{Enum.join(lines, ", ")}, at most #{Map.get(allowed, path, 0)}"
  end

  defp stale(counts, allowed) do
    for {path, ceiling} <- Enum.sort(allowed),
        count = counts |> Map.get(path, []) |> length(),
        count != ceiling,
        do: "#{path}: #{count}, ceiling #{ceiling}"
  end

  # The lines of every `case` that sits in a clause of another `case` in the parsed source. A
  # string's contents are not code, so a `case` spelled out in a heredoc is not counted, and the
  # parser drops comments.
  defp nested_lines(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    ast |> walk(false, []) |> Enum.sort()
  end

  # `inside` is whether the node sits in a clause of a `case` with no `fn` or `&` capture in
  # between.
  defp walk({:fn, _meta, clauses}, _inside, lines), do: walk(clauses, false, lines)
  defp walk({:&, _meta, body}, _inside, lines), do: walk(body, false, lines)

  defp walk({:case, meta, [subject, [do: clauses]]}, inside, lines) do
    lines = if inside, do: [meta[:line] | lines], else: lines
    lines = walk(subject, inside, lines)
    walk(clauses, true, lines)
  end

  # `x |> case do ... end`: the pipe holds the subject, so the `case` keeps only its clauses.
  defp walk({:case, meta, [[do: clauses]]}, inside, lines) do
    lines = if inside, do: [meta[:line] | lines], else: lines
    walk(clauses, true, lines)
  end

  defp walk({form, _meta, args}, inside, lines) when is_list(args),
    do: walk(args, inside, walk(form, inside, lines))

  defp walk({left, right}, inside, lines), do: walk(right, inside, walk(left, inside, lines))

  defp walk(nodes, inside, lines) when is_list(nodes),
    do: Enum.reduce(nodes, lines, &walk(&1, inside, &2))

  defp walk(_leaf, _inside, lines), do: lines
end
