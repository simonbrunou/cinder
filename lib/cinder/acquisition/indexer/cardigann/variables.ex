defmodule Cinder.Acquisition.Indexer.Cardigann.Variables do
  @moduledoc """
  The search variables a Cardigann template reads, by the names Prowlarr's
  `CardigannRequestGenerator` and `CardigannBase.GetBaseTemplateVariables` set (#1671, read at
  Prowlarr `b0b5774`): `.Config.sitelink`, `.Config.<name>` for each setting the definition
  declares, every `.Query.<name>` of `query_names/0`, `.Keywords` and `.Categories`.
  `Cinder.Acquisition.Indexer.Cardigann.Template` sets `.True`, `.False` and `.Today.Year`
  itself.

  `blank/1` holds every name with no value and `filled/1` every name with the text `x`, for the
  load check, which renders a selector template under both (`Cinder.Indexers.Definitions.
  LoadCheck`).
  """

  @query_names ~w(Type Q Series Movie Year Genre IMDBID IMDBIDShort TMDBID TraktID DoubanID
                  Album Artist Label Track Ep Season TVDBID TVRageID TVMazeID Episode Author
                  Title Publisher Categories Limit Offset Extended APIKey Keywords)

  @doc "The `.Query.<name>` names a search sets, without the prefix."
  @spec query_names() :: [String.t()]
  def query_names, do: @query_names

  @doc "Every search variable of `definition`, none with a value (`.Categories` empty)."
  @spec blank(map()) :: map()
  def blank(definition), do: all(definition, nil, [])

  @doc "Every search variable of `definition`, each the text `x` (`.Categories` `[\"x\"]`)."
  @spec filled(map()) :: map()
  def filled(definition), do: all(definition, "x", ["x"])

  defp all(definition, value, list) do
    query =
      Map.new(@query_names, fn
        "Categories" -> {".Query.Categories", list}
        name -> {".Query." <> name, value}
      end)

    config = Map.new(setting_names(definition), &{".Config." <> &1, value})

    query
    |> Map.merge(config)
    |> Map.merge(%{".Config.sitelink" => value, ".Keywords" => value, ".Categories" => list})
  end

  @doc "The names of the settings `definition` declares, in file order."
  @spec setting_names(map()) :: [String.t()]
  def setting_names(definition), do: for(%{name: name} <- definition.settings || [], do: name)
end
