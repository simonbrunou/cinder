defmodule Cinder.CodeHealth.EbookTestModuleNamesTest do
  # #757: `Book*` names the book family, e-books and audiobooks together, and
  # `Cinder.CodeHealthTest` fails a compiled `Book*` module beside an `Audiobook*` sibling. That
  # fence reads `Application.spec(:cinder, :modules)`, so it never sees an `.exs` test module.
  # #814 renamed three e-book-only test modules by hand (`ProwlarrBookTest`, `BookIntentTest`,
  # `BookPollerTest`). This fence holds the same rule for test modules: a `...Book<Rest>Test`
  # beside a `...Audiobook<Rest>Test` under the same parent is the e-book half of a pair, so it is
  # named `...Ebook<Rest>Test`. It pairs names by their text, as the module fence does, so a
  # `...Bookshelf<Rest>Test` beside a `...Audiobookshelf<Rest>Test` fails too. No such pair exists
  # today: rename one half if a pair appears.
  #
  # It reads each `.exs` file under `test/` and takes the file's top-level `defmodule` forms
  # whose name is a plain alias (`defmodule Cinder.FooTest do`), the one form the test files use
  # today. It fails a top-level `defmodule` named any other way, such as `Kernel.defmodule`, an
  # interpolated or computed name, or `__MODULE__`.
  #
  # Forms the walk does not follow include: a `defmodule` nested in a test module, which is a
  # helper; a `defmodule` inside another top-level form, such as the `unless
  # Code.ensure_loaded?(...)` blocks of the migration tests, which hold no test module today; and
  # a module in an `.ex` file under `test/support`, which the `Cinder.CodeHealthTest` fence reads
  # since the test build compiles it into the app.
  use ExUnit.Case, async: true

  test "no Book*Test module has an Audiobook*Test sibling" do
    files = Path.wildcard("test/**/*.exs")

    # A walk that found no files would pass the checks below on nothing.
    assert length(files) > 300

    {names, unread} =
      Enum.reduce(files, {[], []}, fn path, {names, unread} ->
        case test_modules(File.read!(path)) do
          {:ok, found} -> {found ++ names, unread}
          {:error, form} -> {names, ["#{path}: #{form}" | unread]}
        end
      end)

    assert unread == [],
           "this fence reads only `defmodule Plain.Alias do` at a file's top level:\n  " <>
             Enum.join(unread, "\n  ")

    assert "Cinder.Download.AudiobookPollerTest" in names

    # The header leaves `test/support` modules to the `Cinder.CodeHealthTest` fence, which reads
    # the compiled app.
    assert Cinder.ConfigCase in Application.spec(:cinder, :modules)

    offenders = offenders(names)

    assert offenders == [],
           "an e-book-only test module is named Ebook*, not Book*:\n  " <>
             Enum.join(offenders, "\n  ")
  end

  test "a Book*Test is an offender only beside an Audiobook*Test under the same parent" do
    assert offenders(["A.AudiobookPollerTest", "A.BookPollerTest"]) ==
             ["A.BookPollerTest (sibling of A.AudiobookPollerTest)"]

    assert offenders(["A.B.AudiobookPollerTest", "A.B.BookPollerTest"]) ==
             ["A.B.BookPollerTest (sibling of A.B.AudiobookPollerTest)"]

    assert offenders(["A.AudiobookPollerTest", "B.BookPollerTest"]) == []
    assert offenders(["B.AudiobookPollerTest", "A.BookPollerTest"]) == []
    assert offenders(["A.BookPollerRetriedImportErrorsTest"]) == []
    assert offenders(["A.AudiobookPollerTest", "A.EbookPollerTest"]) == []

    assert offenders(["A.AudiobookshelfScanTest", "A.BookshelfScanTest"]) ==
             ["A.BookshelfScanTest (sibling of A.AudiobookshelfScanTest)"]
  end

  test "the reader takes top-level plain-alias test modules and names any other form" do
    assert test_modules("defmodule A.OneTest do\nend\n") == {:ok, ["A.OneTest"]}

    assert test_modules("""
           Code.require_file("x.exs")

           defmodule A.OneTest do
             defmodule InnerTest do
             end
           end

           defmodule A.Helper do
           end
           """) == {:ok, ["A.OneTest"]}

    assert test_modules("""
           defmodule(
             A.SplitTest,
             do: nil
           )
           """) == {:ok, ["A.SplitTest"]}

    assert test_modules("""
           # defmodule A.CommentTest do
           source = "defmodule A.StringTest do end"
           """) == {:ok, []}

    assert test_modules("""
           unless Code.ensure_loaded?(A.Migration) do
             defmodule A.HiddenTest do
             end
           end
           """) == {:ok, []}

    assert {:error, "Kernel.defmodule" <> _} =
             test_modules("Kernel.defmodule A.OneTest do\nend\n")

    assert {:error, "defmodule " <> _} = test_modules("defmodule Module.concat(A, B) do\nend\n")

    assert {:error, "defmodule :\"Elixir.A.\#{name}Test\"" <> _} =
             test_modules(~S|defmodule :"Elixir.A.#{name}Test" do| <> "\nend\n")

    assert {:error, "defmodule __MODULE__.OneTest"} =
             test_modules("defmodule __MODULE__.OneTest do\nend\n")
  end

  defp test_modules(source) do
    forms =
      case Code.string_to_quoted!(source) do
        {:__block__, _, forms} -> forms
        form -> [form]
      end

    Enum.reduce_while(forms, {:ok, []}, fn
      {:defmodule, _, [{:__aliases__, _, parts} | _]}, {:ok, acc} when is_list(parts) ->
        if Enum.all?(parts, &is_atom/1),
          do: {:cont, {:ok, acc ++ test_name(parts)}},
          else: {:halt, {:error, "defmodule " <> Macro.to_string({:__aliases__, [], parts})}}

      {:defmodule, _, [name | _]}, _acc ->
        {:halt, {:error, "defmodule " <> Macro.to_string(name)}}

      {{:., _, [{:__aliases__, _, [:Kernel]}, :defmodule]}, _, _} = form, _acc ->
        {:halt, {:error, form |> Macro.to_string() |> String.split("\n") |> hd()}}

      _other, acc ->
        {:cont, acc}
    end)
  end

  defp test_name(parts) do
    name = Enum.map_join(parts, ".", &Atom.to_string/1)
    if String.ends_with?(name, "Test"), do: [name], else: []
  end

  defp offenders(names) do
    set = MapSet.new(names)

    for name <- Enum.sort(names),
        [last | parent] = name |> String.split(".") |> Enum.reverse(),
        "Audiobook" <> rest <- [last],
        counterpart = Enum.join(Enum.reverse(["Book" <> rest | parent]), "."),
        counterpart in set,
        do: "#{counterpart} (sibling of #{name})"
  end
end
