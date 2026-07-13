defmodule Cinder.Acquisition.AnimePreferences do
  @moduledoc """
  Resolves nullable per-title Anime release preferences against global defaults.

  The returned policy is normalized and carries inheritance provenance for the UI.
  """

  alias Cinder.Acquisition.Language
  alias Ecto.Changeset

  @audio_modes %{
    "original" => :original,
    "dub" => :dub,
    "dual" => :dual,
    "any" => :any
  }
  @embedded_modes %{"allow" => :allow, "prefer" => :prefer, "require" => :require}
  @form_fields ~w(
    audio_mode
    embedded_subtitle_mode
    subtitle_languages_mode
    subtitle_languages
    preferred_release_groups_mode
    preferred_release_groups
    blocked_release_groups_mode
    blocked_release_groups
    group_fallback_delay_mode
    group_fallback_delay_hours
  )

  def resolve(title, defaults) do
    audio_mode = inherited(title.audio_mode, defaults.audio_mode)

    subtitles =
      title.subtitle_languages
      |> inherited_list(defaults.subtitle_languages)
      |> normalize_languages()

    embedded = inherited(title.embedded_subtitle_mode, defaults.embedded_subtitle_mode)

    with {:ok, required_audio} <- required_audio(audio_mode, title),
         :ok <- validate_embedded(embedded, subtitles) do
      {:ok,
       %{
         audio_mode: audio_mode,
         required_audio_languages: required_audio,
         subtitle_languages: subtitles,
         embedded_subtitle_mode: embedded,
         preferred_groups:
           title.preferred_release_groups
           |> inherited_list(defaults.preferred_groups)
           |> normalize_groups(),
         blocked_groups:
           title.blocked_release_groups
           |> inherited_list(defaults.blocked_groups)
           |> normalize_groups(),
         group_fallback_delay:
           inherited(title.group_fallback_delay, defaults.group_fallback_delay),
         provenance: provenance(title)
       }}
    end
  end

  @doc "Parses a per-title form without collapsing inherited and explicitly empty values."
  def override_attrs(params) when is_map(params) do
    with {:ok, audio_mode} <-
           enum_override(params["audio_mode"], @audio_modes, :invalid_audio_mode),
         {:ok, embedded_subtitle_mode} <-
           enum_override(
             params["embedded_subtitle_mode"],
             @embedded_modes,
             :invalid_embedded_subtitle_mode
           ),
         {:ok, subtitle_languages} <-
           list_override(
             params,
             "subtitle_languages",
             &normalize_languages/1,
             :invalid_subtitle_languages_mode
           ),
         {:ok, preferred_release_groups} <-
           list_override(
             params,
             "preferred_release_groups",
             &normalize_groups/1,
             :invalid_preferred_release_groups_mode
           ),
         {:ok, blocked_release_groups} <-
           list_override(
             params,
             "blocked_release_groups",
             &normalize_groups/1,
             :invalid_blocked_release_groups_mode
           ),
         {:ok, group_fallback_delay} <- delay_override(params) do
      {:ok,
       %{
         audio_mode: audio_mode,
         embedded_subtitle_mode: embedded_subtitle_mode,
         subtitle_languages: subtitle_languages,
         preferred_release_groups: preferred_release_groups,
         blocked_release_groups: blocked_release_groups,
         group_fallback_delay: group_fallback_delay
       }}
    end
  end

  @doc "Builds the shared string-keyed form state, overlaid with the last submission."
  def form_state(title, params) when is_map(params) do
    retained_params =
      params
      |> Map.take(@form_fields)
      |> Map.filter(fn {_field, value} -> is_binary(value) end)

    %{
      "audio_mode" => enum_form_value(title.audio_mode),
      "embedded_subtitle_mode" => enum_form_value(title.embedded_subtitle_mode),
      "subtitle_languages_mode" => override_mode(title.subtitle_languages),
      "subtitle_languages" => csv_value(title.subtitle_languages),
      "preferred_release_groups_mode" => override_mode(title.preferred_release_groups),
      "preferred_release_groups" => csv_value(title.preferred_release_groups),
      "blocked_release_groups_mode" => override_mode(title.blocked_release_groups),
      "blocked_release_groups" => csv_value(title.blocked_release_groups),
      "group_fallback_delay_mode" => override_mode(title.group_fallback_delay),
      "group_fallback_delay_hours" => delay_hours(title.group_fallback_delay)
    }
    |> Map.merge(retained_params)
  end

  @doc "Validates the effective candidate and returns field-specific changeset errors."
  def validate_effective(%Changeset{valid?: false} = changeset, _defaults),
    do: {:error, changeset}

  def validate_effective(%Changeset{} = changeset, defaults) do
    case changeset |> Changeset.apply_changes() |> resolve(defaults) do
      {:ok, _policy} ->
        {:ok, changeset}

      {:error, :dub_language_required} ->
        {:error, Changeset.add_error(changeset, :audio_mode, "is invalid")}

      {:error, :original_language_required} ->
        {:error,
         Changeset.add_error(changeset, :audio_mode, "requires original language metadata")}

      {:error, :subtitle_language_required} ->
        {:error, Changeset.add_error(changeset, :subtitle_languages, "can't be blank")}
    end
  end

  def snapshot(policy, release) do
    %{
      "version" => 1,
      "required_audio_languages" => policy.required_audio_languages,
      "required_embedded_subtitle_languages" =>
        if(policy.embedded_subtitle_mode == :require,
          do: policy.subtitle_languages,
          else: []
        ),
      "release_group" => normalize_group(release.group),
      "release_title" => release.title
    }
  end

  @doc "Whether a frozen release policy is the exact normalized version-1 document."
  def valid_snapshot?(nil, _release_title), do: true

  def valid_snapshot?(snapshot, release_title) when is_map(snapshot) do
    case snapshot do
      %{
        "version" => 1,
        "required_audio_languages" => required_audio,
        "required_embedded_subtitle_languages" => required_subtitles,
        "release_group" => release_group,
        "release_title" => snapshot_title
      } ->
        map_size(snapshot) == 5 and snapshot_title == release_title and
          nonblank_string?(snapshot_title) and normalized_languages?(required_audio) and
          normalized_languages?(required_subtitles) and
          normalized_optional_group?(release_group)

      _invalid ->
        false
    end
  end

  def valid_snapshot?(_snapshot, _release_title), do: false

  @doc "Whether positive Anime release evidence does not contradict the resolved policy."
  def release_allowed?(release, policy), do: verdict(release, policy) == :ok

  @doc "Returns the Anime policy rejection reason used by the manual-search surface."
  def verdict(release, policy) do
    cond do
      group_blocked?(release.group, policy.blocked_groups) ->
        {:rejected, :blocked_anime_group}

      contradictory_audio?(release, policy.required_audio_languages) ->
        {:rejected, :contradictory_audio}

      contradictory_subtitles?(release, policy) ->
        {:rejected, :contradictory_subtitles}

      true ->
        :ok
    end
  end

  @doc "Ascending Anime-only soft preference key; unknown evidence sorts after a positive match."
  def rank_key(release, policy) do
    {
      if(policy.preferred_groups == [] or preferred_group?(release, policy), do: 0, else: 1),
      if(policy.required_audio_languages == [] or explicit_audio_match?(release, policy),
        do: 0,
        else: 1
      ),
      if(
        policy.embedded_subtitle_mode == :allow or policy.subtitle_languages == [] or
          explicit_subtitle_match?(release, policy),
        do: 0,
        else: 1
      )
    }
  end

  @doc "The legacy timing options plus the resolved Anime policy consumed by selection."
  def selection_opts(policy) do
    [
      anime_policy: policy,
      preferred_groups: policy.preferred_groups,
      fallback_delay: policy.group_fallback_delay
    ]
  end

  def normalize_languages(nil), do: []

  def normalize_languages(languages) do
    languages
    |> Enum.map(&Language.normalize/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  def normalize_optional_languages(nil), do: nil
  def normalize_optional_languages(languages), do: normalize_languages(languages)

  def normalize_groups(nil), do: []

  def normalize_groups(groups) do
    groups
    |> Enum.map(&normalize_group/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  def normalize_optional_groups(nil), do: nil
  def normalize_optional_groups(groups), do: normalize_groups(groups)

  def normalize_group(nil), do: nil
  def normalize_group(group), do: group |> String.trim() |> String.downcase()

  defp normalized_languages?(languages) when is_list(languages) do
    Enum.all?(languages, &nonblank_string?/1) and normalize_languages(languages) == languages
  end

  defp normalized_languages?(_languages), do: false

  defp normalized_optional_group?(nil), do: true

  defp normalized_optional_group?(group) do
    nonblank_string?(group) and normalize_group(group) == group
  end

  defp nonblank_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp group_blocked?(group, blocked), do: normalize_group(group) in blocked

  defp preferred_group?(release, policy),
    do: normalize_group(release.group) in policy.preferred_groups

  defp contradictory_audio?(%{audio_claim_complete?: true} = release, required)
       when required != [] do
    not Enum.all?(required, &Language.audio_satisfies?(&1, release.audio_languages || []))
  end

  defp contradictory_audio?(_release, _required), do: false

  defp contradictory_subtitles?(release, %{embedded_subtitle_mode: :require} = policy) do
    release.embedded_subtitle_claim == :absent or
      (release.embedded_subtitle_claim == :present and
         release.embedded_subtitle_languages != [] and
         not Enum.any?(policy.subtitle_languages, fn wanted ->
           Language.audio_satisfies?(wanted, release.embedded_subtitle_languages)
         end))
  end

  defp contradictory_subtitles?(_release, _policy), do: false

  defp explicit_audio_match?(release, policy) do
    release.audio_claim_complete? and
      Enum.all?(policy.required_audio_languages, fn wanted ->
        Language.audio_satisfies?(wanted, release.audio_languages || [])
      end)
  end

  defp explicit_subtitle_match?(release, policy) do
    release.embedded_subtitle_claim == :present and
      Enum.any?(policy.subtitle_languages, fn wanted ->
        Language.audio_satisfies?(wanted, release.embedded_subtitle_languages || [])
      end)
  end

  defp enum_override(value, _modes, _error) when value in [nil, "", "inherit"], do: {:ok, nil}

  defp enum_override(value, modes, error) do
    case Map.fetch(modes, value) do
      {:ok, mode} -> {:ok, mode}
      :error -> {:error, error}
    end
  end

  defp list_override(params, field, normalize, error) do
    case params[field <> "_mode"] do
      mode when mode in [nil, "", "inherit"] ->
        {:ok, nil}

      "override" ->
        case params[field] do
          value when is_binary(value) or is_nil(value) ->
            {:ok, value |> split_csv() |> normalize.()}

          _other ->
            {:error, error}
        end

      _other ->
        {:error, error}
    end
  end

  defp delay_override(params) do
    case params["group_fallback_delay_mode"] do
      mode when mode in [nil, "", "inherit"] -> {:ok, nil}
      "override" -> parse_delay_hours(params["group_fallback_delay_hours"])
      _other -> {:error, :invalid_group_fallback_delay}
    end
  end

  defp parse_delay_hours(hours) when is_binary(hours) do
    case Integer.parse(String.trim(hours)) do
      {hours, ""} when hours >= 0 -> {:ok, hours * 3_600}
      _other -> {:error, :invalid_group_fallback_delay}
    end
  end

  defp parse_delay_hours(_hours), do: {:error, :invalid_group_fallback_delay}

  defp split_csv(nil), do: []
  defp split_csv(value), do: String.split(value, ",")

  defp enum_form_value(nil), do: "inherit"
  defp enum_form_value(value), do: Atom.to_string(value)

  defp override_mode(nil), do: "inherit"
  defp override_mode(_value), do: "override"

  defp csv_value(nil), do: ""
  defp csv_value(values), do: Enum.join(values, ", ")

  defp delay_hours(nil), do: ""
  defp delay_hours(seconds), do: seconds |> div(3_600) |> Integer.to_string()

  defp required_audio(:original, title), do: {:ok, original_languages(title)}
  defp required_audio(:any, _title), do: {:ok, []}

  defp required_audio(:dub, title) do
    with {:ok, dub_language} <- dub_language(title) do
      {:ok, [dub_language]}
    end
  end

  defp required_audio(:dual, title) do
    with {:ok, dub_language} <- dub_language(title),
         [original_language | _rest] <- original_languages(title) do
      {:ok, Enum.uniq([original_language, dub_language])}
    else
      [] -> {:error, :original_language_required}
      {:error, _reason} = error -> error
    end
  end

  defp original_languages(title) do
    title.original_language
    |> List.wrap()
    |> normalize_languages()
    |> Enum.filter(&Language.known?/1)
  end

  defp dub_language(%{preferred_language: preferred})
       when preferred in [nil, "", "original", "any"],
       do: {:error, :dub_language_required}

  defp dub_language(%{preferred_language: preferred}) do
    case Language.normalize(preferred) do
      "" -> {:error, :dub_language_required}
      normalized -> {:ok, normalized}
    end
  end

  defp validate_embedded(:require, []), do: {:error, :subtitle_language_required}
  defp validate_embedded(_mode, _languages), do: :ok

  defp inherited(nil, default), do: default
  defp inherited(value, _default), do: value

  defp inherited_list(nil, default), do: default
  defp inherited_list(value, _default), do: value

  defp provenance(title) do
    %{
      audio_mode: source(title.audio_mode),
      subtitle_languages: source(title.subtitle_languages),
      embedded_subtitle_mode: source(title.embedded_subtitle_mode),
      preferred_groups: source(title.preferred_release_groups),
      blocked_groups: source(title.blocked_release_groups),
      group_fallback_delay: source(title.group_fallback_delay)
    }
  end

  defp source(nil), do: :inherited
  defp source(_value), do: :overridden
end
