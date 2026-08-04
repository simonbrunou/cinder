defmodule Cinder.Download.Intent do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias Cinder.Acquisition.AnimePreferences
  alias Cinder.Catalog.{AnimeResolver, TitleAlias}
  alias Cinder.Util

  schema "download_intents" do
    field :operation_key, :string
    field :kind, Ecto.Enum, values: [:movie, :episode, :season_pack]
    field :target_id, :integer
    field :episode_ids, {:array, :integer}, default: []
    field :protocol, Ecto.Enum, values: [:torrent, :usenet]
    field :release, :map
    field :mapping_snapshot, :map
    field :release_policy_snapshot, :map

    field :status, Ecto.Enum,
      values: [:reserved, :submitted, :cleanup_pending],
      default: :reserved

    field :remote_id, :string
    field :attempt_count, :integer, default: 0
    field :next_attempt_at, :utc_datetime
    field :last_error, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(intent, attrs) do
    intent
    |> cast(attrs, [
      :operation_key,
      :kind,
      :target_id,
      :episode_ids,
      :protocol,
      :release,
      :status,
      :remote_id,
      :attempt_count,
      :next_attempt_at,
      :last_error
    ])
    |> validate_required([:operation_key, :kind, :target_id, :protocol, :release, :status])
    |> unique_constraint(:operation_key)
    |> unique_constraint(:target_id)
  end

  def reservation_changeset(%__MODULE__{id: nil} = intent, attrs) do
    intent
    |> changeset(attrs)
    |> cast(attrs, [:mapping_snapshot, :release_policy_snapshot])
    |> validate_mapping_snapshot()
    |> validate_release_policy_snapshot()
  end

  def reservation_changeset(%__MODULE__{} = intent, attrs) do
    intent
    |> changeset(attrs)
    |> add_error(:mapping_snapshot, "is immutable")
    |> add_error(:release_policy_snapshot, "is immutable")
  end

  defp validate_release_policy_snapshot(changeset) do
    release_title =
      case get_field(changeset, :release) do
        %{"title" => title} -> title
        _release -> nil
      end

    if AnimePreferences.valid_snapshot?(
         get_field(changeset, :release_policy_snapshot),
         release_title
       ) do
      changeset
    else
      add_error(changeset, :release_policy_snapshot, "is invalid")
    end
  end

  defp validate_mapping_snapshot(changeset) do
    snapshot = get_field(changeset, :mapping_snapshot)

    if valid_mapping_snapshot?(
         snapshot,
         get_field(changeset, :kind),
         get_field(changeset, :episode_ids)
       ) do
      changeset
    else
      add_error(changeset, :mapping_snapshot, "is invalid")
    end
  end

  @doc "Whether a mapping snapshot satisfies the durable intent reservation contract."
  def valid_mapping_snapshot?(nil, _kind, _episode_ids), do: true

  def valid_mapping_snapshot?(snapshot, kind, intent_episode_ids)
      when kind in [:episode, :season_pack] and is_map(snapshot) do
    with %{
           "reserved_episode_ids" => reserved_ids,
           "release" => release,
           "mappings" => mappings,
           "selected_resolution" => selected
         } <- snapshot,
         true <- valid_snapshot_version?(snapshot),
         true <- valid_episode_ids?(reserved_ids),
         true <- reserved_ids == intent_episode_ids,
         true <- valid_release?(release),
         true <- valid_release_scopes?(release, snapshot["parser_context"]),
         {:ok, mapping_index} <- mapping_index(mappings, reserved_ids),
         true <- valid_scene_title_bindings?(snapshot["parser_context"], mappings),
         true <- mappings_cover?(mappings, reserved_ids),
         true <- valid_selected_resolution?(selected, release, mapping_index, reserved_ids) do
      true
    else
      _invalid -> false
    end
  end

  def valid_mapping_snapshot?(_snapshot, _kind, _episode_ids), do: false

  defp valid_snapshot_version?(%{
         "version" => 2,
         "parser_context" => %{"title" => title, "aliases" => aliases, "year" => year} = context
       }) do
    Util.present?(title) and is_list(aliases) and length(aliases) <= 7 and
      Enum.all?(aliases, &Util.present?/1) and (is_nil(year) or is_integer(year)) and
      valid_scene_titles?(Map.get(context, "scene_titles", []), aliases, title)
  end

  defp valid_snapshot_version?(_snapshot), do: false

  defp valid_scene_titles?(scene_titles, aliases, canonical_title)
       when is_list(scene_titles) and length(scene_titles) <= 7 do
    canonical = TitleAlias.normalize(canonical_title)

    known_aliases =
      aliases
      |> Enum.map(&TitleAlias.normalize/1)
      |> Enum.reject(&(&1 == canonical))
      |> MapSet.new()

    normalized = Enum.map(scene_titles, &valid_scene_title_entry(&1, known_aliases))

    Enum.all?(normalized, &is_binary/1) and Enum.uniq(normalized) == normalized
  end

  defp valid_scene_titles?(_scene_titles, _aliases, _canonical_title), do: false

  defp valid_scene_title_entry(
         %{
           "title" => title,
           "season" => season,
           "source" => "tmdb",
           "namespace" => namespace
         },
         known_aliases
       )
       when is_binary(title) and is_integer(season) and season >= 0 and season <= 999 and
              is_binary(namespace) do
    normalized_title = TitleAlias.normalize(title)

    if Util.present?(title) and Util.present?(namespace) and
         MapSet.member?(known_aliases, normalized_title),
       do: normalized_title
  end

  defp valid_scene_title_entry(_scene_title, _known_aliases), do: nil

  defp valid_scene_title_bindings?(context, mappings) do
    Enum.all?(Map.get(context, "scene_titles", []), fn scene_title ->
      title = scene_title["title"]
      season = scene_title["season"]
      source = scene_title["source"]
      namespace = scene_title["namespace"]

      Enum.any?(mappings, fn mapping ->
        identity = mapping["identity"]

        identity["source"] == source and identity["scheme"] == "scene" and
          identity["namespace"] == namespace and
          scene_value_in_season?(identity["canonical_value"], season) and
          TitleAlias.normalize(mapping["scope_title"] || "") == TitleAlias.normalize(title)
      end)
    end)
  end

  defp scene_value_in_season?(value, season) when is_binary(value) and is_integer(season) do
    case Regex.run(~r/^S(\d{2,3})E\d{2,4}$/u, value, capture: :all_but_first) do
      [value_season] -> String.to_integer(value_season) == season
      _invalid -> false
    end
  end

  defp scene_value_in_season?(_value, _season), do: false

  defp valid_release?(%{"coordinates" => coordinates}) when is_list(coordinates) do
    coordinates != [] and Enum.all?(coordinates, &valid_coordinate?/1)
  end

  defp valid_release?(_release), do: false

  defp valid_release_scopes?(%{"coordinates" => coordinates}, context) do
    scene_titles = Map.get(context, "scene_titles", [])
    Enum.all?(coordinates, &valid_release_coordinate_scope?(&1, scene_titles))
  end

  defp valid_release_coordinate_scope?(
         %{"source" => source, "namespace" => namespace} = coordinate,
         scene_titles
       ) do
    coordinate["scheme"] == "scene" and source == "tmdb" and
      Enum.any?(scene_titles, fn scene_title ->
        scene_title["source"] == source and scene_title["namespace"] == namespace and
          Enum.all?(
            coordinate["values"],
            &scene_value_in_season?(&1, scene_title["season"])
          )
      end)
  end

  defp valid_release_coordinate_scope?(_coordinate, _scene_titles), do: true

  defp valid_coordinate?(%{"scheme" => scheme, "values" => values} = coordinate) do
    Util.present?(scheme) and is_list(values) and values != [] and
      Enum.all?(values, &Util.present?/1) and valid_scope?(coordinate)
  end

  defp valid_coordinate?(_coordinate), do: false

  defp valid_scope?(%{"source" => source, "namespace" => namespace}),
    do: Util.present?(source) and Util.present?(namespace)

  defp valid_scope?(coordinate),
    do: not Map.has_key?(coordinate, "source") and not Map.has_key?(coordinate, "namespace")

  defp mapping_index(mappings, reserved_ids) when is_list(mappings) and mappings != [] do
    if Enum.all?(mappings, &valid_mapping?(&1, reserved_ids)) do
      index = Map.new(mappings, &{&1["identity"], &1})
      if map_size(index) == length(mappings), do: {:ok, index}, else: :error
    else
      :error
    end
  end

  defp mapping_index(_mappings, _reserved_ids), do: :error

  defp valid_mapping?(
         %{"identity" => identity, "precedence" => precedence, "episode_ids" => episode_ids} =
           mapping,
         reserved_ids
       ) do
    valid_identity?(identity) and valid_precedence?(precedence) and
      valid_episode_ids?(episode_ids) and intersects?(episode_ids, reserved_ids) and
      valid_optional_scope_title?(Map.get(mapping, "scope_title"))
  end

  defp valid_mapping?(_mapping, _reserved_ids), do: false

  defp valid_optional_scope_title?(nil), do: true
  defp valid_optional_scope_title?(title), do: Util.present?(title)

  defp valid_identity?(%{
         "source" => source,
         "scheme" => scheme,
         "namespace" => namespace,
         "canonical_value" => canonical_value
       }) do
    Enum.all?([source, scheme, namespace, canonical_value], &Util.present?/1)
  end

  defp valid_identity?(_identity), do: false

  defp valid_selected_resolution?(
         %{"episode_ids" => episode_ids, "values" => values},
         release,
         mapping_index,
         reserved_ids
       )
       when is_list(values) and values != [] do
    episode_ids == reserved_ids and
      Enum.all?(values, &valid_selected_value?(&1, mapping_index)) and
      coordinate_pairs(release["coordinates"]) == selected_pairs(values) and
      Enum.uniq(Enum.flat_map(values, & &1["episode_ids"])) == episode_ids
  end

  defp valid_selected_resolution?(_selected, _release, _mapping_index, _reserved_ids),
    do: false

  defp valid_selected_value?(
         %{
           "scheme" => scheme,
           "canonical_value" => canonical_value,
           "episode_ids" => episode_ids,
           "precedence" => precedence,
           "mapping_identities" => identities
         } = value,
         mapping_index
       ) do
    Util.present?(scheme) and Util.present?(canonical_value) and valid_scope?(value) and
      valid_episode_ids?(episode_ids) and valid_precedence?(precedence) and
      is_list(identities) and identities != [] and Enum.uniq(identities) == identities and
      Enum.all?(identities, fn identity ->
        valid_selected_reference?(
          identity,
          mapping_index,
          value,
          precedence,
          episode_ids
        )
      end)
  end

  defp valid_selected_value?(_value, _mapping_index), do: false

  defp valid_selected_reference?(
         identity,
         mapping_index,
         value,
         precedence,
         episode_ids
       ) do
    with true <- valid_identity?(identity),
         {:ok, mapping} <- Map.fetch(mapping_index, identity) do
      selected_reference_matches?(identity, value) and
        mapping["precedence"] == precedence and mapping["episode_ids"] == episode_ids
    else
      _missing -> false
    end
  end

  defp selected_reference_matches?(
         identity,
         %{
           "scheme" => scheme,
           "canonical_value" => canonical_value,
           "source" => source,
           "namespace" => namespace
         }
       ) do
    identity["source"] == source and identity["scheme"] == scheme and
      identity["namespace"] == namespace and identity["canonical_value"] == canonical_value
  end

  defp selected_reference_matches?(
         identity,
         %{"scheme" => scheme, "canonical_value" => canonical_value}
       ) do
    identity["scheme"] in [scheme | AnimeResolver.bridged_schemes(scheme)] and
      identity["canonical_value"] == canonical_value
  end

  defp mappings_cover?(mappings, reserved_ids) do
    mapped = mappings |> Enum.flat_map(& &1["episode_ids"]) |> MapSet.new()
    MapSet.subset?(MapSet.new(reserved_ids), mapped)
  end

  defp coordinate_pairs(coordinates) do
    for %{"scheme" => scheme, "values" => values} = coordinate <- coordinates,
        value <- values,
        do: {scheme, value, coordinate["source"], coordinate["namespace"]}
  end

  defp selected_pairs(values) do
    Enum.map(
      values,
      &{&1["scheme"], &1["canonical_value"], &1["source"], &1["namespace"]}
    )
  end

  defp valid_episode_ids?(ids) when is_list(ids) and ids != [],
    do: Enum.all?(ids, &(is_integer(&1) and &1 > 0))

  defp valid_episode_ids?(_ids), do: false

  defp intersects?(left, right) do
    not MapSet.disjoint?(MapSet.new(left), MapSet.new(right))
  end

  defp valid_precedence?(precedence), do: precedence in ["manual", "curated", "inferred"]
end
