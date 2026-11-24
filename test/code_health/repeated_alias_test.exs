defmodule Cinder.CodeHealth.RepeatedAliasTest do
  # A module body names each alias once. On #1587 `disk_test.exs` held `alias Cinder.ConfigCase`
  # twice with a blank line between the two lines. The compile and `credo --strict` gates passed,
  # and a review re-check reported the repeat.
  #
  # The walk reads the `alias` forms directly in each `defmodule` body under lib/ and test/, with
  # a nested module as its own body, also one nested in a `def`, `test` or `quote`. It reads the
  # forms those bodies use today: `alias A.B`, `alias __MODULE__.B`, `alias A.{B, C}` and
  # `alias A.B, as: C`, where `as: B` is the plain alias. It fails on any other `alias(...)` call
  # or pipe through `alias` directly in such a body, so a new form gets read or refused here. Two
  # lines that give one module different `as:` names are not a repeat.
  # Forms the walk does not follow include: an `alias` directly inside a `def`, `test`,
  # `describe`, `setup`, `if`, `quote`, `defimpl` or `defprotocol`, in a parenthesised block
  # beside other forms, nested in another expression (`_ = alias A.B`, `@a alias(A.B)`, a call's
  # argument, a tuple), at a file's top level, in a `Kernel.defmodule` body, or from a macro; one
  # module spelled two ways, as `__MODULE__.B` beside its full name, `Elixir.A.B` beside `A.B`,
  # or `B.C` through an earlier `alias A.B` beside `A.B.C`.
  use ExUnit.Case, async: true

  @sources "{lib,test}/**/*.{ex,exs}"

  test "the scan reads lib/ and test/, both .ex and .exs" do
    paths = Path.wildcard(@sources)

    for path <- ~w(lib/cinder/disk.ex test/support/data_case.ex test/cinder/disk_test.exs) do
      assert path in paths
    end
  end

  test "no module body under lib/ or test/ repeats an alias" do
    found =
      for path <- Path.wildcard(@sources),
          name <- repeated_aliases(File.read!(path), path) do
        "#{path}: #{name}"
      end

    assert found == [], "Remove the second alias line:\n" <> Enum.join(found, "\n")
  end

  describe "the walk" do
    test "finds a plain alias named twice, across a blank line" do
      assert repeated_aliases("""
             defmodule M do
               alias A.B

               alias A.B
             end
             """) == ["A.B"]
    end

    test "reports a name written three times once" do
      assert repeated_aliases("""
             defmodule M do
               alias A.B
               alias A.B
               alias A.B
             end
             """) == ["A.B"]
    end

    test "finds a name repeated inside one multi-alias" do
      assert repeated_aliases("""
             defmodule M do
               alias A.{B, B}
             end
             """) == ["A.B"]
    end

    test "finds a multi-alias repeat split across lines" do
      assert repeated_aliases("""
             defmodule M do
               alias A.{
                 B,
                 B
               }
             end
             """) == ["A.B"]
    end

    test "finds a plain alias that a multi-alias repeats" do
      assert repeated_aliases("""
             defmodule M do
               alias A.B
               alias A.{B, C}
             end
             """) == ["A.B"]
    end

    test "finds one module with one `as:` name twice, split across lines" do
      assert repeated_aliases("""
             defmodule M do
               alias A.B, as: C

               alias A.B,
                 as: C
             end
             """) == ["A.B as C"]
    end

    test "reads `as:` with the last segment as the plain alias" do
      assert repeated_aliases("""
             defmodule M do
               alias A.B
               alias A.B, as: B
             end
             """) == ["A.B"]
    end

    test "finds `__MODULE__.B` named twice" do
      assert repeated_aliases("""
             defmodule M do
               alias __MODULE__.B
               alias __MODULE__.B
             end
             """) == ["__MODULE__.B"]
    end

    test "reports a repeat in each of two modules" do
      assert repeated_aliases("""
             defmodule M do
               alias A.B
               alias A.B
             end

             defmodule N do
               alias C.D
               alias C.D
             end
             """) == ["A.B", "C.D"]
    end

    test "accepts one module under two `as:` names" do
      assert repeated_aliases("""
             defmodule M do
               alias A.B
               alias A.B, as: C
             end
             """) == []
    end

    test "reads a nested module as its own body" do
      assert repeated_aliases("""
             defmodule M do
               alias A.B

               defmodule N do
                 alias A.B
               end
             end
             """) == []
    end

    test "finds a repeat inside a nested module" do
      assert repeated_aliases("""
             defmodule M do
               defmodule N do
                 alias A.B
                 alias A.B
               end
             end
             """) == ["A.B"]
    end

    test "skips an alias in a comment and in a string" do
      assert repeated_aliases(~S'''
             defmodule M do
               alias A.B
               # alias A.B
               @doc "alias A.B"
               @text """
               alias A.B
               """
             end
             ''') == []
    end

    test "reads a variable named alias as no alias" do
      assert repeated_aliases("""
             defmodule M do
               alias
               alias
             end
             """) == []
    end

    test "reads a parenthesised block that is the whole body" do
      assert repeated_aliases("""
             defmodule M do
               (alias A.B; alias A.B)
             end
             """) == ["A.B"]
    end

    test "reads a body pipe that calls no alias as no alias" do
      assert repeated_aliases("""
             defmodule M do
               alias |> foo()
               alias |> foo()
             end
             """) == []
    end

    test "reads an empty multi-alias as no names" do
      assert repeated_aliases("""
             defmodule M do
               alias A.{}
               alias A.{}
             end
             """) == []
    end

    for {label, wrapper} <- [
          {"def", "def f do"},
          {"test", "test \"t\" do"},
          {"quote", "quote do"}
        ] do
      test "finds a repeat in a module nested in a `#{label}`" do
        source = """
        defmodule M do
          #{unquote(wrapper)}
            defmodule N do
              alias A.B
              alias A.B
            end
          end
        end
        """

        assert repeated_aliases(source) == ["A.B"]
      end
    end

    for {label, form} <- [
          {"a bare __MODULE__", "alias __MODULE__"},
          {"an atom target", "alias :crypto, as: Crypto"},
          {"an unquoted target", "alias unquote(target)"},
          {"an unquoted head", "alias unquote(x).B"},
          {"a variable head", "alias foo.B"},
          {"an attribute head", "alias @m.B"},
          {"an unquoted head with `as:`", "alias unquote(x).B, as: C"},
          {"a multi-alias on __MODULE__", "alias __MODULE__.{B, C}"},
          {"a multi-alias on __MODULE__.X", "alias __MODULE__.X.{B, C}"},
          {"a multi-alias on an unquoted head", "alias unquote(x).A.{B, C}"},
          {"a multi-alias child that is no alias", "alias A.{unquote(b), C}"},
          {"a multi-alias child with an unquoted head", "alias A.{unquote(x).B, C}"},
          {"a multi-alias with options", "alias A.{B, C}, warn: false"},
          {"a `warn:` option", "alias A.B, warn: false"},
          {"`as:` beside another option", "alias A.B, as: C, warn: false"},
          {"an `as:` name of two segments", "alias A.B, as: C.D"},
          {"options in a variable", "alias A.B, opts"},
          {"three arguments", "alias(A, B, C)"},
          {"a call head on __MODULE__", "alias __MODULE__().B"},
          {"a pipe into alias", "A.B |> alias()"},
          {"a pipe into alias with no parentheses", "A.B |> alias"},
          {"a pipe into alias with `as:`", "A.B |> alias(as: C)"},
          {"a pipe through alias", "A.B |> alias() |> then(& &1)"},
          {"a pipe through alias with no parentheses", "A.B |> alias |> then(& &1)"},
          {"a pipe out of alias", "alias(A.B) |> then(& &1)"}
        ] do
      test "fails on #{label}, naming the file and the form" do
        source = "defmodule M do\n  #{unquote(form)}\nend\n"

        error = assert_raise ArgumentError, fn -> repeated_aliases(source, "lib/m.ex") end
        assert error.message =~ "lib/m.ex:2"
        assert error.message =~ source |> Code.string_to_quoted!() |> form_text()
      end
    end

    for {label, source} <- [
          {"a `def`", "defmodule M do\n  def f do\n    alias A.B\n    alias A.B\n  end\nend\n"},
          {"a `test`",
           "defmodule M do\n  test \"t\" do\n    alias A.B\n    alias A.B\n  end\nend\n"},
          {"a `describe`",
           "defmodule M do\n  describe \"d\" do\n    alias A.B\n    alias A.B\n  end\nend\n"},
          {"a `quote`", "defmodule M do\n  quote do\n    alias A.B\n    alias A.B\n  end\nend\n"},
          {"a `defimpl`",
           "defmodule M do\n  defimpl P do\n    alias A.B\n    alias A.B\n  end\nend\n"},
          {"a `defprotocol`", "defprotocol P do\n  alias A.B\n  alias A.B\nend\n"},
          {"a `setup`", "defmodule M do\n  setup do\n    alias A.B\n    alias A.B\n  end\nend\n"},
          {"an `if`", "defmodule M do\n  if x do\n    alias A.B\n    alias A.B\n  end\nend\n"},
          {"a parenthesised block beside other forms",
           "defmodule M do\n  (alias A.B; alias A.B)\n  :ok\nend\n"},
          {"a match", "defmodule M do\n  _ = alias A.B\n  _ = alias A.B\nend\n"},
          {"an attribute value", "defmodule M do\n  @a alias(A.B)\n  @b alias(A.B)\nend\n"},
          {"a call's argument",
           "defmodule M do\n  IO.inspect(alias A.B)\n  IO.inspect(alias A.B)\nend\n"},
          {"a tuple", "defmodule M do\n  {alias(A.B), 1}\n  {alias(A.B), 1}\nend\n"},
          {"a `Kernel.defmodule` body", "Kernel.defmodule M do\n  alias A.B\n  alias A.B\nend\n"},
          {"a file's top level", "alias A.B\nalias A.B\n"},
          {"`__MODULE__.B` beside its full name",
           "defmodule M do\n  alias __MODULE__.B\n  alias M.B\nend\n"},
          {"an `Elixir.` prefix", "defmodule M do\n  alias Elixir.A.B\n  alias A.B\nend\n"},
          {"a name reached through an earlier alias",
           "defmodule M do\n  alias A.B\n  alias B.C\n  alias A.B.C\nend\n"}
        ] do
      test "does not follow #{label}" do
        assert repeated_aliases(unquote(source)) == []
      end
    end
  end

  defp form_text({:defmodule, _meta, [_name, [do: form]]}), do: Macro.to_string(form)

  defp repeated_aliases(source, path \\ "fixture") do
    {_ast, names} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:defmodule, _meta, [_name, [do: body]]} = node, names ->
          {node, repeats(body, path) ++ names}

        node, names ->
          {node, names}
      end)

    Enum.sort(names)
  end

  defp repeats(body, path) do
    names = body |> body_forms() |> Enum.flat_map(&alias_names(&1, path))
    Enum.uniq(names -- Enum.uniq(names))
  end

  defp body_forms({:__block__, _meta, forms}), do: forms
  defp body_forms(form), do: [form]

  defp alias_names({:alias, _meta, [{{:., _, [base, :{}]}, _, children}]} = form, path) do
    if Enum.all?([base | children], &atom_segments?/1) do
      Enum.map(children, &"#{Macro.to_string(base)}.#{Macro.to_string(&1)}")
    else
      unreadable(form, path)
    end
  end

  defp alias_names(
         {:alias, _meta, [{:__aliases__, _, segments} = target, [as: {:__aliases__, _, [name]}]]} =
           form,
         path
       ) do
    cond do
      not target_segments?(segments) -> unreadable(form, path)
      name == List.last(segments) -> [Macro.to_string(target)]
      true -> ["#{Macro.to_string(target)} as #{name}"]
    end
  end

  defp alias_names({:alias, _meta, [{:__aliases__, _, segments} = target]} = form, path) do
    if target_segments?(segments), do: [Macro.to_string(target)], else: unreadable(form, path)
  end

  defp alias_names({:alias, _meta, args} = form, path) when is_list(args),
    do: unreadable(form, path)

  defp alias_names({:|>, _meta, _args} = form, path) do
    [{head, _position} | calls] = Macro.unpipe(form)

    calls_alias? =
      match?({:alias, _, args} when is_list(args), head) or
        Enum.any?(calls, &match?({{:alias, _, _}, _}, &1))

    if calls_alias?, do: unreadable(form, path), else: []
  end

  defp alias_names(_form, _path), do: []

  defp atom_segments?({:__aliases__, _meta, segments}), do: Enum.all?(segments, &is_atom/1)
  defp atom_segments?(_form), do: false

  defp target_segments?([{:__MODULE__, _meta, context} | rest]) when is_atom(context),
    do: Enum.all?(rest, &is_atom/1)

  defp target_segments?(segments), do: Enum.all?(segments, &is_atom/1)

  defp unreadable({_call, meta, _args} = form, path) do
    raise ArgumentError,
          "#{path}:#{meta[:line]}: this fence cannot read `#{Macro.to_string(form)}`. Teach " <>
            "test/code_health/repeated_alias_test.exs the form, or write the alias another way."
  end
end
