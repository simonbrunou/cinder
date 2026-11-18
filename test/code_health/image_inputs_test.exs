defmodule Cinder.CodeHealth.ImageInputsTest do
  # #1486: CI's `container` job skips on a pull request that changes no path of image-inputs.txt.
  # The first test fails `mix test` when the list misses a path the build or the job reads, as
  # `Cinder.ImageInputs` (test/support/image_inputs.ex) finds them; the rest run that reader on
  # fixtures, one per form it reads or fails on. Its moduledoc lists them.
  use ExUnit.Case, async: true

  alias Cinder.ImageInputs

  @dockerfile ~S"""
  FROM debian AS builder
  COPY mix.exs mix.lock ./
  # copy compile-time config files
  COPY config/config.exs config/${MIX_ENV}.exs config/
  COPY lib lib
  RUN mix compile \
    && mix release
  COPY rel rel
  FROM debian AS final
  COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/cinder ./
  """

  @list Enum.join(ImageInputs.fixed() ++ ~w(mix.exs mix.lock config lib rel), "\n") <> "\n"

  test "image-inputs.txt covers every path the Dockerfile and the container job read" do
    {out, 0} = System.cmd("git", ["ls-files", "-s", "-z"])

    entries =
      for entry <- String.split(out, <<0>>, trim: true) do
        [meta, path] = String.split(entry, "\t", parts: 2)
        {hd(String.split(meta, " ")), path}
      end

    read = fn path -> if File.regular?(path), do: File.read(path), else: :error end

    assert ImageInputs.problems(entries, read) == [],
           "Add each path below to image-inputs.txt, or fix the line it names. A pull request " <>
             "that changes a path the list misses skips CI's container job."
  end

  test "the list's block \"The build and the job\" holds the fixed paths, in order" do
    block =
      File.read!("image-inputs.txt")
      |> String.split("\n")
      |> Enum.drop_while(&(not String.starts_with?(&1, "# The build and the job")))
      |> Enum.drop_while(&String.starts_with?(&1, "#"))
      |> Enum.take_while(&(&1 != ""))

    assert block == ImageInputs.fixed()
  end

  test "the fixture passes" do
    assert problems(%{}) == []
  end

  describe "a path the list misses" do
    test "a COPY source" do
      assert problems(%{"image-inputs.txt" => list_without("rel")}) == [
               "Dockerfile:8: reads rel from the build context, which no line of " <>
                 "image-inputs.txt covers"
             ]
    end

    test "each fixed path" do
      for path <- ImageInputs.fixed() do
        assert problems(%{"image-inputs.txt" => list_without(path)}) == [
                 "image-inputs.txt: no line covers #{path}, which the build or the container " <>
                   "job reads"
               ]
      end
    end

    test "a source cut at a variable or a glob, back to its folder" do
      for {line, path} <- [
            {"COPY config/${MIX_ENV}.exs config/", "config"},
            {"COPY assets/*.js assets/", "assets"},
            {"COPY assets/js/app?.js assets/", "assets/js"},
            {"COPY priv/[a-z]* priv/", "priv"},
            {"COPY ./priv/./static/ priv/", "priv/static"}
          ] do
        fixed_only = Enum.join(ImageInputs.fixed(), "\n") <> "\n"

        assert {line, problems(%{"Dockerfile" => line <> "\n", "image-inputs.txt" => fixed_only})} ==
                 {line,
                  [
                    "Dockerfile:1: reads #{path} from the build context, which no line of " <>
                      "image-inputs.txt covers"
                  ]}
      end
    end

    test "a line that names a longer path, or a path under a source, does not cover it" do
      list = list_without("lib") <> "lib/cinder\nlibrary\n"

      assert problems(%{"image-inputs.txt" => list}) == [
               "Dockerfile:5: reads lib from the build context, which no line of " <>
                 "image-inputs.txt covers"
             ]
    end

    test "a COPY or ADD in any case, after spaces, a byte order mark, or inside a continued RUN" do
      for dockerfile <- [
            "copy rel rel\n",
            "\tAdd rel rel\n",
            "#{<<0xFEFF::utf8>>}COPY rel rel\n",
            "#{<<0xA0::utf8, 0x2003::utf8>>}COPY#{<<0xA0::utf8>>}rel rel\n",
            "COPY --chown=nobody:root --chmod=755 --link rel rel\n",
            "COPY --ch\"o\"wn=nobody rel rel\n",
            "RUN echo a \\\nCOPY rel rel\n",
            "RUN <<EOF\nCOPY rel rel\nEOF\n"
          ] do
        assert {dockerfile,
                problems(%{"Dockerfile" => dockerfile, "image-inputs.txt" => list_without("rel")})} ==
                 {dockerfile,
                  [
                    "Dockerfile:#{line_of(dockerfile, "rel rel")}: reads rel from the build " <>
                      "context, which no line of image-inputs.txt covers"
                  ]}
      end
    end
  end

  describe "a path the list covers" do
    test "through a folder above it, on a last line with no newline" do
      list = list_without("config") <> "config"
      assert problems(%{"image-inputs.txt" => list}) == []
    end

    test "a COPY from a stage or an image, its flag spelled through quotes or an escape" do
      for line <- [
            "COPY --from=builder /app/x ./",
            "COPY --chown=nobody --from=builder outside ./",
            ~S(COPY --fr"o"m=builder outside ./),
            ~S(COPY --fr\om=docker.io/library/debian outside ./)
          ] do
        assert {line, problems(%{"Dockerfile" => line <> "\n"})} == {line, []}
      end
    end

    test "a line that only names a COPY in prose, or a RUN with arguments" do
      dockerfile = "# COPY outside ./\nRUN copy outside \\\n  && make\nCOPYING outside\n"
      assert problems(%{"Dockerfile" => dockerfile}) == []
    end
  end

  describe "a form the reader cannot read" do
    test "fails on the line that holds it" do
      for {line, problem} <- [
            {"COPY", "a COPY with no source"},
            {"COPY lib", "a COPY with no source"},
            {"COPY --chown=nobody lib", "a COPY with no source"},
            {"COPY lib \\", "a COPY continued on the next line"},
            {"COPY lib `", "a COPY continued on the next line"},
            {"COPY <<EOF /x", "a COPY heredoc"},
            {~S(COPY ["lib", "lib"]), "a COPY in the JSON form"},
            {"COPY --parents lib lib", "a COPY flag this check cannot read: --parents"},
            {"COPY --exclude=*.md lib lib", "a COPY flag this check cannot read: --exclude=*.md"},
            {"COPY --chown lib lib", "a COPY flag this check cannot read: --chown"},
            {"ADD --checksum=sha256:00 a b", "an ADD flag this check cannot read"},
            {"ADD https://example.com/x /x", "an ADD of a URL or a git address"},
            {"ADD git@example.com:a/b.git /b", "an ADD of a URL or a git address"},
            {~S(COPY "lib" lib), "a COPY source this check cannot read: \"lib\""},
            {~S(COPY l\ib lib), "a COPY source this check cannot read"},
            {"COPY /lib lib", "a COPY source this check cannot read: /lib"},
            {"COPY lib/../rel rel", "a COPY source this check cannot read: lib/../rel"},
            {"COPY . .", "a COPY source that reads the whole build context"},
            {"COPY ./ app/", "a COPY source that reads the whole build context"},
            {"COPY *.exs ./", "a COPY source that reads the whole build context"},
            {"COPY ${DIR}/lib lib", "a COPY source that reads the whole build context"},
            {"RUN --mount=type=bind,target=/src make", "a RUN whose first argument is a flag"},
            {~S(RUN "--mount=target=/src" make), "a RUN whose first argument is a flag"},
            {"RUN \\", "a RUN whose first argument is a flag or sits on the next line"},
            {"CO\\\nPY extra.txt /x", "a word continued on the next line"},
            {"COPY\\", "a word continued on the next line"},
            {"  \\", "a word continued on the next line"},
            {"RUN", "a RUN whose first argument is a flag or sits on the next line"},
            {"ONBUILD COPY lib lib", "an ONBUILD"},
            {"# syntax=docker/dockerfile:1", "a parser directive"},
            {"#escape=`", "a parser directive"},
            {"  # ESCAPE = \\", "a parser directive"},
            {"//syntax=docker.io/docker/dockerfile:1", "a parser directive"}
          ] do
        found = problems(%{"Dockerfile" => line <> "\n"})
        assert match?([_one], found), "#{line}: #{inspect(found)}"
        [found] = found
        assert {line, found =~ "Dockerfile:1: " <> problem} == {line, true}, found
      end
    end

    # The job's bash and scripts/merge-pr drop a NUL byte where this check sees it, and a bash
    # range such as [a-z] can take a letter outside ASCII. This check fails each such line, so
    # its test, which a merge needs green, holds the list to the lines all three read alike.
    test "a list line outside the path form, and each line that fails" do
      for line <- [
            "l#{<<0>>}ib",
            "l\u00EDb",
            "lib\t",
            "lib/",
            "/lib",
            "./lib",
            "lib//x",
            "lib/../rel",
            "..",
            "l*b",
            "lib\r",
            " lib",
            "lib ",
            "#{<<0xFEFF::utf8>>}lib",
            "lib # the code"
          ] do
        list = @list <> line <> "\n"
        number = length(String.split(@list, "\n"))

        assert {line, problems(%{"image-inputs.txt" => list})} ==
                 {line,
                  [
                    "image-inputs.txt:#{number}: #{inspect(line)} is not a path the " <>
                      "image-inputs job reads (letters, digits, ., _, - and /, with no empty, " <>
                      ". or .. part), so the job fails"
                  ]}
      end
    end

    test "a list with no path, a missing list and a missing Dockerfile" do
      [first | _rest] = problems(%{"image-inputs.txt" => "# nothing\n\n"})
      assert first == "image-inputs.txt: no path, so the image-inputs job fails"

      [first | _rest] = problems(%{"image-inputs.txt" => nil})
      assert first == "image-inputs.txt: no such file, so the image-inputs job fails"

      assert problems(%{"Dockerfile" => nil}) == ["Dockerfile: no such file"]
    end

    test "a symbolic link or a submodule at, above or under a required path" do
      for {link, path, place} <- [
            {"rel", "rel", "Dockerfile:8"},
            {"config", "config/config.exs", "Dockerfile:4"},
            {"lib/cinder/vendored", "lib", "Dockerfile:5"},
            {".github", ".github/scripts", "image-inputs.txt"},
            {".trivyignore", ".trivyignore", "image-inputs.txt"}
          ] do
        found = problems(%{}, [{"120000", link}])

        assert {link,
                ("#{place}: #{path} has the symbolic link or submodule #{link} at, above or " <>
                   "under it, whose changes a diff over #{path} cannot see") in found} ==
                 {link, true},
               Enum.join(found, "\n")
      end

      assert [_problem] = problems(%{}, [{"160000", "lib/vendored"}])
      assert problems(%{}, [{"120000", "CLAUDE.md"}, {"120000", "library"}]) == []
    end
  end

  # The reader's problems for the fixture tree with `files` laid over it (nil drops a file) and
  # `links` added as `{mode, path}` entries.
  defp problems(files, links \\ []) do
    tree =
      %{"Dockerfile" => @dockerfile, "image-inputs.txt" => @list}
      |> Map.merge(files)
      |> Enum.reject(fn {_path, text} -> text == nil end)
      |> Map.new()

    entries = Enum.map(tree, fn {path, _text} -> {"100644", path} end) ++ links
    ImageInputs.problems(entries, &Map.fetch(tree, &1))
  end

  defp list_without(path) do
    lines = String.split(@list, "\n")
    assert path in lines, "the fixture list holds no line #{path}"
    Enum.join(lines -- [path], "\n")
  end

  defp line_of(text, fragment) do
    text |> String.split("\n") |> Enum.find_index(&String.contains?(&1, fragment)) |> Kernel.+(1)
  end
end
