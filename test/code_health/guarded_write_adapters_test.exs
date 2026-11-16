defmodule Cinder.CodeHealth.GuardedWriteAdaptersTest do
  # #743: a guarded-write adapter is reachable only through its owner, so no caller can write a
  # movie status around a `MovieLifecycle` verb, or a request around the approval gate. The fence
  # fails on any mention of an adapter's name in `lib/` outside its own file and its owner's.
  # Every static spelling of a module holds its last segment whole, so this substring scan
  # catches each form an AST walk of aliases and calls would, plus three that walk misses: the
  # `:"Elixir.<module>"` atom, a comment and a string. Forms the scan does not catch include a
  # name built at runtime, such as `Module.concat/2` on the name's parts.
  use ExUnit.Case, async: true

  # adapter => {its own file, its owner}
  @adapters %{
    "MovieTransition" =>
      {"lib/cinder/catalog/movie_transition.ex", "lib/cinder/catalog/movie_lifecycle.ex"},
    "EpisodeTransition" =>
      {"lib/cinder/catalog/episode_transition.ex", "lib/cinder/catalog/episodes.ex"},
    "GrabTransition" => {"lib/cinder/catalog/grab_transition.ex", "lib/cinder/catalog/grabs.ex"},
    "BookTargetTransition" =>
      {"lib/cinder/books/book_target_transition.ex", "lib/cinder/books.ex"},
    "RequestTransition" => {"lib/cinder/requests/request_transition.ex", "lib/cinder/requests.ex"}
  }

  test "only its owner names each guarded-write adapter" do
    offenders =
      for(path <- Path.wildcard("lib/**/*.ex"), do: {path, File.read!(path)})
      |> offenders()

    assert offenders == [],
           "call the owner's guarded write instead of naming its adapter:\n  " <>
             Enum.join(offenders, "\n  ")
  end

  # A wrong path in @adapters fails the scan above, since the file that defines or owns the
  # adapter names it; a module missing from @adapters fails here. The test reads each module's
  # behaviours from its `.beam` file in the app's `ebin` directory, so it loads no module:
  # calling `module_info/1` loads each module not yet loaded through the code server, and on a
  # loaded CI runner that wait outlasted ExUnit's 60 s test timeout (#1351). A `.beam` file the
  # test cannot read fails it, naming the module.
  test "@adapters lists every Cinder.GuardedWrite adapter" do
    adapters =
      for {module, behaviours} <- read_behaviours(Application.spec(:cinder, :modules)),
          Cinder.GuardedWrite in behaviours,
          into: MapSet.new(),
          do: module |> Module.split() |> List.last()

    assert adapters == @adapters |> Map.keys() |> MapSet.new()
  end

  test "a module whose .beam file cannot be read fails the behaviour read" do
    error = assert_raise ExUnit.AssertionError, fn -> read_behaviours([Cinder.NoSuchModule]) end
    assert error.message =~ "\n  Cinder.NoSuchModule: "
  end

  test "the scan fails each static spelling of an adapter's name, in code, a comment or a string" do
    forms = [
      "alias Cinder.Catalog.GrabTransition",
      "alias Cinder.Catalog.GrabTransition, as: Write",
      "alias Cinder.Catalog.{Grab, GrabTransition}",
      "alias Cinder.Catalog.{\n  Grab,\n  GrabTransition\n}",
      "Cinder.Catalog.GrabTransition.publish([])",
      "Cinder.Catalog.\n  GrabTransition.publish([])",
      ~S|:"Elixir.Cinder.Catalog.GrabTransition".publish([])|,
      "# GrabTransition writes the row",
      ~S|@doc "Writes through GrabTransition."|
    ]

    for form <- forms do
      assert offenders([{"lib/cinder/other.ex", form}]) ==
               ["lib/cinder/other.ex names GrabTransition (owner: lib/cinder/catalog/grabs.ex)"],
             "the scan missed: #{form}"
    end
  end

  test "only an adapter's own file and its own owner may name it" do
    alias_grab = "alias Cinder.Catalog.GrabTransition"

    assert offenders([
             {"lib/cinder/catalog/grabs.ex", alias_grab},
             {"lib/cinder/catalog/grab_transition.ex", alias_grab}
           ]) == []

    assert offenders([{"lib/cinder/catalog/grabs.ex", "alias Cinder.Catalog.MovieTransition"}]) ==
             [
               "lib/cinder/catalog/grabs.ex names MovieTransition " <>
                 "(owner: lib/cinder/catalog/movie_lifecycle.ex)"
             ]
  end

  test "a name built at runtime passes the scan" do
    source = ~S|Module.concat([Cinder.Catalog, "Grab" <> "Transition"]).publish([])|
    assert offenders([{"lib/cinder/other.ex", source}]) == []
  end

  defp read_behaviours(modules) do
    ebin = Application.app_dir(:cinder, "ebin")
    reads = for module <- modules, do: {module, beam_behaviours(ebin, module)}

    unreadable =
      for {module, {:error, error}} <- reads, do: "#{inspect(module)}: #{inspect(error)}"

    assert unreadable == [],
           "cannot read the behaviours from these modules' .beam files:\n  " <>
             Enum.join(unreadable, "\n  ")

    for {module, {:ok, behaviours}} <- reads, do: {module, behaviours}
  end

  defp beam_behaviours(ebin, module) do
    path = ebin |> Path.join("#{module}.beam") |> String.to_charlist()

    case :beam_lib.chunks(path, [:attributes]) do
      {:ok, {^module, [attributes: attributes]}} ->
        {:ok, attributes |> Keyword.get_values(:behaviour) |> List.flatten()}

      other ->
        {:error, other}
    end
  end

  defp offenders(sources) do
    for {path, source} <- sources,
        {adapter, {own, owner}} <- Enum.sort(@adapters),
        String.contains?(source, adapter),
        path not in [own, owner],
        do: "#{path} names #{adapter} (owner: #{owner})"
  end
end
