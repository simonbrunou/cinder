defmodule Cinder.Download.Intent do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  schema "download_intents" do
    field :operation_key, :string
    field :kind, Ecto.Enum, values: [:movie, :episode, :season_pack]
    field :target_id, :integer
    field :episode_ids, {:array, :integer}, default: []
    field :protocol, Ecto.Enum, values: [:torrent, :usenet]
    field :release, :map
    field :mapping_snapshot, :map

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
    |> cast(attrs, [:mapping_snapshot])
    |> validate_mapping_snapshot()
  end

  def reservation_changeset(%__MODULE__{} = intent, attrs) do
    intent
    |> changeset(attrs)
    |> add_error(:mapping_snapshot, "is immutable")
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

  defp valid_mapping_snapshot?(nil, _kind, _episode_ids), do: true

  defp valid_mapping_snapshot?(snapshot, kind, intent_episode_ids)
       when kind in [:episode, :season_pack] and is_map(snapshot) do
    with %{
           "version" => 1,
           "reserved_episode_ids" => reserved_ids,
           "release" => release,
           "mappings" => mappings,
           "selected_resolution" => selected
         } <- snapshot,
         true <- valid_episode_ids?(reserved_ids),
         true <- reserved_ids == intent_episode_ids,
         true <- valid_release?(release),
         {:ok, mapping_index} <- mapping_index(mappings, reserved_ids),
         true <- mappings_cover?(mappings, reserved_ids),
         true <- valid_selected_resolution?(selected, release, mapping_index, reserved_ids) do
      true
    else
      _invalid -> false
    end
  end

  defp valid_mapping_snapshot?(_snapshot, _kind, _episode_ids), do: false

  defp valid_release?(%{"coordinates" => coordinates}) when is_list(coordinates) do
    coordinates != [] and Enum.all?(coordinates, &valid_coordinate?/1)
  end

  defp valid_release?(_release), do: false

  defp valid_coordinate?(%{"scheme" => scheme, "values" => values}) do
    nonempty_string?(scheme) and is_list(values) and values != [] and
      Enum.all?(values, &nonempty_string?/1)
  end

  defp valid_coordinate?(_coordinate), do: false

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
         %{"identity" => identity, "precedence" => precedence, "episode_ids" => episode_ids},
         reserved_ids
       ) do
    valid_identity?(identity) and valid_precedence?(precedence) and
      valid_episode_ids?(episode_ids) and intersects?(episode_ids, reserved_ids)
  end

  defp valid_mapping?(_mapping, _reserved_ids), do: false

  defp valid_identity?(%{
         "source" => source,
         "scheme" => scheme,
         "namespace" => namespace,
         "canonical_value" => canonical_value
       }) do
    Enum.all?([source, scheme, namespace, canonical_value], &nonempty_string?/1)
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
      coordinate_pairs(release["coordinates"]) == selected_pairs(values) and
      Enum.all?(values, &valid_selected_value?(&1, mapping_index)) and
      ordered_uniq(Enum.flat_map(values, & &1["episode_ids"])) == episode_ids
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
         },
         mapping_index
       ) do
    nonempty_string?(scheme) and nonempty_string?(canonical_value) and
      valid_episode_ids?(episode_ids) and valid_precedence?(precedence) and
      is_list(identities) and identities != [] and Enum.uniq(identities) == identities and
      Enum.all?(identities, fn identity ->
        valid_selected_reference?(
          identity,
          mapping_index,
          scheme,
          canonical_value,
          precedence,
          episode_ids
        )
      end)
  end

  defp valid_selected_value?(_value, _mapping_index), do: false

  defp valid_selected_reference?(
         identity,
         mapping_index,
         scheme,
         canonical_value,
         precedence,
         episode_ids
       ) do
    with true <- valid_identity?(identity),
         {:ok, mapping} <- Map.fetch(mapping_index, identity) do
      identity["scheme"] == scheme and identity["canonical_value"] == canonical_value and
        mapping["precedence"] == precedence and mapping["episode_ids"] == episode_ids
    else
      _missing -> false
    end
  end

  defp mappings_cover?(mappings, reserved_ids) do
    mapped = mappings |> Enum.flat_map(& &1["episode_ids"]) |> MapSet.new()
    MapSet.subset?(MapSet.new(reserved_ids), mapped)
  end

  defp coordinate_pairs(coordinates) do
    for %{"scheme" => scheme, "values" => values} <- coordinates,
        value <- values,
        do: {scheme, value}
  end

  defp selected_pairs(values) do
    Enum.map(values, &{&1["scheme"], &1["canonical_value"]})
  end

  defp valid_episode_ids?(ids) when is_list(ids) and ids != [],
    do: Enum.all?(ids, &(is_integer(&1) and &1 > 0))

  defp valid_episode_ids?(_ids), do: false

  defp intersects?(left, right) do
    not MapSet.disjoint?(MapSet.new(left), MapSet.new(right))
  end

  defp valid_precedence?(precedence), do: precedence in ["manual", "curated", "inferred"]

  defp nonempty_string?(value),
    do: is_binary(value) and String.trim(value) != ""

  defp ordered_uniq(values) do
    {ordered, _seen} =
      Enum.reduce(values, {[], MapSet.new()}, fn value, {ordered, seen} ->
        if MapSet.member?(seen, value) do
          {ordered, seen}
        else
          {[value | ordered], MapSet.put(seen, value)}
        end
      end)

    Enum.reverse(ordered)
  end
end
