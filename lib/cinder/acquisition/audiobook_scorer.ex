defmodule Cinder.Acquisition.AudiobookScorer do
  @moduledoc """
  Judges one audiobook release against one requested work, and ranks the survivors.

  The `Cinder.Acquisition.BookScorer` sibling for audiobooks, copying its `evaluate/3`/
  `evaluate_all/3` shape and fail-closed rejection philosophy verbatim (per the B7a plan's "new
  sibling modules, not widened e-book ones" decision) with three deltas:

    * `@accepted_formats [:m4b, :mp3]` and a `5 MB – 8 GB` size band, instead of the e-book
      profile/band. **Both are this module's own judgment call** (§0.1 of the B7a audiobook
      plan), not contract-derived — the parity contract only names M4B as preferred and gestures
      at "common multipart audio containers" for later milestones without enumerating a size or
      duration band, exactly like `BookScorer`'s own 64 KB – 200 MB band is that module's
      attribute-level judgment rather than a contract number.
    * A narrator credit in a bracketed group ("(Narrated by Ray Porter)", "[Read by ...]") is
      treated as release metadata for title matching, the same way a format or retail tag is —
      see `check_title/2`'s narrator-group handling below.
    * **No narrator check.** Narrator evidence in a release name is real but unreliable — many
      releases omit it, some misattribute a series narrator to a guest reader — and there is no
      B0 corpus measurement of narrator-name precision to gate a rejection on. Inventing a
      threshold here would repeat the unfounded-precision-bar mistake B5's own §0 already flagged
      and refused to repeat for release selection. `narrator` rides through to `evidence` for
      informational display only; it never changes accept/reject.

  Every other check — format contradiction, author/title evidence, collection ambiguity,
  abridgement, language, protocol, blocklist — is the identical fail-closed logic `BookScorer`
  already ships, against the audiobook vocabulary instead of the e-book one.
  """

  alias Cinder.Acquisition.AudiobookParser
  alias Cinder.Acquisition.AudiobookRelease
  alias Cinder.Acquisition.Parser
  alias Cinder.Books.TitleFold

  # B7a's own judgment (§0.1) — the two formats the roadmap names by name, M4B preferred. NOT
  # contract-derived; see the moduledoc.
  @accepted_formats [:m4b, :mp3]

  # B7a's own judgment (§0.1) — an order of magnitude above BookScorer's e-book band, matched to
  # real MP3/AAC bitrates across a 1-40+ hour audiobook. NOT contract-derived.
  @min_size 5 * 1024 * 1024
  @max_size 8 * 1024 * 1024 * 1024

  # An untagged release is this language by scene convention — see `check_language/2`.
  @default_language "en"

  # Function words that mark descriptive prose rather than a title-case noun phrase.
  @function_words ~w(a an the of and or in on to for from with without at by is are its it
                     how why what when who where life story history guide)

  # The single words in `AudiobookParser`'s collection patterns. A work whose own title contains
  # one of these is asking for something that legitimately reads as a collection, so the marker
  # stops being evidence against the release.
  @collection_words ~w(omnibus anthology collection collections boxset boxsets complete)

  # Leftover words that are release metadata rather than part of a work's identity — the
  # audiobook vocabulary sibling of `BookScorer`'s own list. `narrated`/`read`/`by` cover the
  # rare bare (unbracketed) narrator credit; the bracketed form is stripped entirely by
  # `check_title/2`'s narrator-group handling before this list is ever consulted.
  @edition_annotations ~w(
    retail audiobook m4b mp3 m4a aac flac ogg wma
    edition ed abridged unabridged illustrated annotated revised reprint
    v1 v2 v3 vol volume by narrated read rip
  )

  # The parser's own format vocabulary, so a format token can never read as a title word.
  @format_tokens AudiobookParser.known_formats() |> Enum.map(&Atom.to_string/1)

  @type evidence :: %{
          format: atom(),
          formats: [atom()],
          language: String.t() | nil,
          retail?: boolean(),
          size: non_neg_integer() | nil,
          query_origins: [atom()] | nil,
          narrator: String.t() | nil
        }

  # The single source of truth for every rejection reason `evaluate/3` can return — the identical
  # closed vocabulary `BookScorer` already has (no new rejection kind; a second scorer producing
  # the same vocabulary against different bands). See `BookScorer`'s own note on why `@type
  # reason` is generated from this list rather than the reverse.
  @reasons [
    :format_unknown,
    :format_rejected,
    :author_mismatch,
    :title_mismatch,
    :collection_ambiguous,
    :language_mismatch,
    :wrong_protocol,
    :title_unfoldable,
    :abridged_edition,
    :format_contradictory,
    :size_out_of_band,
    :blocked_term,
    :blocklisted
  ]

  @type reason :: unquote(Enum.reduce(@reasons, &{:|, [], [&1, &2]}))

  @doc "The audiobook formats the profile accepts, most preferred first."
  @spec accepted_formats() :: [atom()]
  def accepted_formats, do: @accepted_formats

  @doc "The inclusive size band, in bytes, as `{min, max}`."
  @spec size_band() :: {pos_integer(), pos_integer()}
  def size_band, do: {@min_size, @max_size}

  @doc "Every rejection reason `evaluate/3` can return — see `BookScorer.reasons/0`'s own note."
  @spec reasons() :: [reason()]
  def reasons, do: @reasons

  @doc """
  Judges `release` against `work`. Mirrors `BookScorer.evaluate/3`'s options and check ordering
  exactly — see its docs for `:language`, `:blocked_terms`, `:release_blocklist`, `:protocols`.
  """
  @spec evaluate(AudiobookRelease.t(), map(), keyword()) ::
          {:accept, evidence()} | {:reject, reason()}
  def evaluate(%AudiobookRelease{} = release, work, opts \\ []) do
    with :ok <- check_not_blocklisted(release, Keyword.get(opts, :release_blocklist) || []),
         :ok <- check_blocked(release, Keyword.get(opts, :blocked_terms) || []),
         {:ok, format} <- check_format(release),
         :ok <- check_protocol(release, Keyword.get(opts, :protocols)),
         :ok <- check_author(release, Map.get(work, :authors) || []),
         :ok <- check_collection(release, work),
         :ok <- check_abridgement(release, work),
         :ok <- check_title(release, work),
         :ok <- check_language(release, Keyword.get(opts, :language)),
         :ok <- check_size(release) do
      {:accept,
       %{
         format: format,
         formats: release.formats || [],
         language: release.language,
         retail?: release.retail? || false,
         size: release.size,
         query_origins: release.query_origins,
         narrator: release.narrator
       }}
    end
  end

  @doc "Evaluates every release and partitions the results. Mirrors `BookScorer.evaluate_all/3`."
  @spec evaluate_all([AudiobookRelease.t()], map(), keyword()) :: %{
          accepted: [{AudiobookRelease.t(), evidence()}],
          rejected: [{AudiobookRelease.t(), reason()}]
        }
  def evaluate_all(releases, work, opts \\ []) do
    {accepted, rejected} =
      releases
      |> Enum.map(&{&1, evaluate(&1, work, opts)})
      |> Enum.split_with(fn {_release, result} -> match?({:accept, _evidence}, result) end)

    %{
      accepted:
        accepted
        |> Enum.map(fn {release, {:accept, evidence}} -> {release, evidence} end)
        |> Enum.sort_by(fn {release, evidence} ->
          rank(release, evidence, Keyword.get(opts, :language))
        end),
      rejected: Enum.map(rejected, fn {release, {:reject, reason}} -> {release, reason} end)
    }
  end

  # Ascending sort, so every component is written "smaller is better" — the identical ranking
  # shape `BookScorer.rank/3` uses.
  defp rank(%AudiobookRelease{} = release, evidence, wanted_language) do
    {
      Enum.find_index(@accepted_formats, &(&1 == evidence.format)),
      language_rank(evidence.language, wanted_language),
      if(evidence.retail?, do: 0, else: 1),
      release.size || @max_size,
      published_rank(release.published_at),
      release.title || ""
    }
  end

  defp language_rank(nil, nil), do: 0
  defp language_rank("MULTI", nil), do: 1
  defp language_rank(_tagged, nil), do: 2

  defp language_rank(language, wanted) do
    cond do
      language == tag_for(wanted) -> 0
      language == "MULTI" -> 1
      is_nil(language) -> 2
      true -> 3
    end
  end

  defp published_rank(nil), do: 0
  defp published_rank(%DateTime{} = published_at), do: -DateTime.to_unix(published_at)

  defp check_not_blocklisted(_release, []), do: :ok

  defp check_not_blocklisted(%AudiobookRelease{title: title}, blocklist) do
    down = String.downcase(title || "")

    if Enum.any?(blocklist, &(String.downcase(&1 || "") == down)),
      do: {:reject, :blocklisted},
      else: :ok
  end

  defp check_blocked(_release, []), do: :ok

  defp check_blocked(%AudiobookRelease{title: title}, terms) do
    down = String.downcase(title || "")

    if Enum.any?(terms, &blocked_term?(down, &1)),
      do: {:reject, :blocked_term},
      else: :ok
  end

  defp blocked_term?(down, term) do
    normalized = term |> to_string() |> String.trim() |> String.downcase()
    normalized != "" and String.contains?(down, normalized)
  end

  defp check_format(%AudiobookRelease{formats: formats}) do
    formats = formats || []
    {accepted, rejected} = Enum.split_with(formats, &(&1 in @accepted_formats))

    cond do
      formats == [] -> {:reject, :format_unknown}
      accepted == [] -> {:reject, :format_rejected}
      rejected != [] -> {:reject, :format_contradictory}
      true -> {:ok, Enum.find(@accepted_formats, &(&1 in accepted))}
    end
  end

  defp check_author(_release, []), do: {:reject, :author_mismatch}

  defp check_author(%AudiobookRelease{title: title}, authors) do
    release_tokens = tokens(title)

    if Enum.any?(authors, &author_present?(&1, release_tokens)),
      do: :ok,
      else: {:reject, :author_mismatch}
  end

  defp author_present?(author, release_tokens) do
    author_tokens = tokens(author)
    author_tokens != [] and author_tokens -- release_tokens == []
  end

  defp check_title(%AudiobookRelease{title: release_title}, work) do
    wanted = work |> Map.fetch!(:title) |> tokens() |> drop_article()

    core =
      release_title
      |> strip_noise(work)
      |> tokens()
      |> subtract_matched_author(Map.get(work, :authors) || [])
      |> drop_article()

    leftovers = Enum.reject(core -- wanted, &metadata_token?(&1, work))

    cond do
      TitleFold.lossy?(Map.fetch!(work, :title)) or TitleFold.lossy?(release_title) ->
        {:reject, :title_unfoldable}

      wanted == [] ->
        {:reject, :title_mismatch}

      wanted -- core != [] ->
        {:reject, :title_mismatch}

      leftovers == [] ->
        :ok

      subtitle_only?(release_title, wanted, leftovers, work) ->
        :ok

      true ->
        {:reject, :title_mismatch}
    end
  end

  defp strip_noise(nil, _work), do: ""

  defp strip_noise(title, work) do
    title
    |> drop_bracketed_groups(work)
    |> String.replace(~r/-[A-Za-z0-9]+$/, " ")
    |> String.replace(~r/\b(?:book|bk|vol|volume|part|pt|no|nr)\b[ .#]*\d{1,3}\b/i, " ")
    |> String.replace(~r/#\d{1,3}\b/, " ")
    |> String.replace(~r/(?<=[-–—:.,]|\s)\d{1,3}(?=\s*[-–—:.,]|\s|$)/, " ")
  end

  # Same bracket-drop shape `BookScorer.drop_bracketed_groups/2` uses, plus one addition: a
  # narrator-credit group ("Narrated by Ray Porter", "Read by ...") is dropped unconditionally,
  # regardless of whether the narrator's NAME is itself recognized metadata. A narrator's name is
  # release evidence, not part of the work's identity — leaving it unstripped would make an
  # unrecognized narrator name read as a title mismatch, which is exactly the narrator-as-gate
  # outcome the moduledoc says this scorer must never produce.
  defp drop_bracketed_groups(title, work) do
    ~r/[\[\(\{]([^\]\)\}]*)[\]\)\}]?/
    |> Regex.split(title, include_captures: true, trim: true)
    |> Enum.reduce({[], false}, &keep_segment(&1, &2, work))
    |> then(fn {kept, _seen} -> kept |> Enum.reverse() |> Enum.join() end)
  end

  defp keep_segment(segment, {kept, metadata_seen?}, work) do
    case Regex.run(~r/^[\[\(\{]([^\]\)\}]*)[\]\)\}]?$/, segment) do
      [_group, inner] -> keep_group(inner, kept, metadata_seen?, work)
      nil -> {[segment | kept], metadata_seen?}
    end
  end

  @narrator_group ~r/^\s*(?:narrated|read)\s+by\s+.+$/i

  defp keep_group(inner, kept, metadata_seen?, work) do
    inner_tokens = tokens(inner)

    cond do
      Regex.match?(@narrator_group, inner) ->
        {[" " | kept], true}

      inner_tokens != [] and Enum.all?(inner_tokens, &metadata_token?(&1, work)) ->
        {[" " | kept], true}

      metadata_seen? and tracker_tag?(inner) ->
        {[" " | kept], metadata_seen?}

      true ->
        {[" " <> inner <> " " | kept], metadata_seen?}
    end
  end

  defp tracker_tag?(inner) do
    word = String.trim(inner)

    Regex.match?(~r/^[A-Za-z0-9]+$/, word) and
      (Regex.match?(~r/[a-z][A-Z]/, word) or Regex.match?(~r/\d/, word))
  end

  defp subtitle_only?(release_title, wanted, leftovers, work) do
    case String.split(strip_noise(release_title, work), ~r/:/, parts: 2) do
      [head, subtitle] ->
        head_tokens =
          head
          |> tokens()
          |> subtract_matched_author(Map.get(work, :authors) || [])
          |> drop_article()

        wanted -- head_tokens == [] and
          Enum.all?(head_tokens -- wanted, &metadata_token?(&1, work)) and
          leftovers != [] and
          descriptive_subtitle?(subtitle, wanted)

      _no_colon ->
        false
    end
  end

  defp descriptive_subtitle?(subtitle, wanted) do
    subtitle_tokens = tokens(subtitle)

    restates_title? = wanted != [] and wanted -- subtitle_tokens == []

    length(subtitle_tokens) >= 3 and
      Enum.any?(subtitle_tokens, &(&1 in @function_words)) and
      not restates_title?
  end

  defp language_token?(token) do
    upper = String.upcase(token)

    upper == "MULTI" or
      Enum.any?(Parser.language_tags(), fn {code, tag} -> upper == tag or token == code end)
  end

  defp subtract_matched_author(release_tokens, authors) do
    authors
    |> Enum.map(&tokens/1)
    |> Enum.sort_by(&{-length(&1), &1})
    |> Enum.find(fn author_tokens ->
      author_tokens != [] and author_tokens -- release_tokens == []
    end)
    |> case do
      nil -> release_tokens
      author_tokens -> release_tokens -- author_tokens
    end
  end

  defp metadata_token?(token, work) do
    token in @edition_annotations or
      language_token?(token) or
      Regex.match?(~r/^(?:19|20)\d{2}$/, token) or
      token in @format_tokens or
      token in series_tokens(work)
  end

  defp series_tokens(work) do
    work
    |> Map.get(:series)
    |> List.wrap()
    |> Enum.flat_map(&tokens/1)
  end

  defp check_collection(%AudiobookRelease{collection?: true} = release, work) do
    wanted = work |> Map.fetch!(:title) |> tokens() |> MapSet.new()

    if release.title |> tokens() |> Enum.any?(&(&1 in @collection_words and &1 in wanted)),
      do: :ok,
      else: {:reject, :collection_ambiguous}
  end

  defp check_collection(%AudiobookRelease{}, _work), do: :ok

  defp check_abridgement(%AudiobookRelease{abridged?: true}, work) do
    if Map.get(work, :abridged) == true, do: :ok, else: {:reject, :abridged_edition}
  end

  defp check_abridgement(%AudiobookRelease{}, _work), do: :ok

  defp check_protocol(_release, nil), do: :ok
  defp check_protocol(%AudiobookRelease{protocol: nil}, _protocols), do: :ok

  defp check_protocol(%AudiobookRelease{protocol: protocol}, protocols)
       when is_list(protocols) do
    if protocol in protocols, do: :ok, else: {:reject, :wrong_protocol}
  end

  defp check_protocol(%AudiobookRelease{}, _protocols), do: :ok

  defp check_language(_release, nil), do: :ok
  defp check_language(%AudiobookRelease{language: "MULTI"}, _wanted), do: :ok

  defp check_language(%AudiobookRelease{language: nil}, wanted) do
    if tag_for(wanted) == tag_for(@default_language),
      do: :ok,
      else: {:reject, :language_mismatch}
  end

  defp check_language(%AudiobookRelease{language: language}, wanted) do
    if language == tag_for(wanted), do: :ok, else: {:reject, :language_mismatch}
  end

  defp tag_for(wanted) do
    wanted = wanted |> to_string() |> String.downcase()

    canonical =
      Enum.find_value(Parser.audio_codes(), wanted, fn {code, aliases} ->
        if wanted == code or wanted in aliases, do: code
      end)

    Map.get(Parser.language_tags(), canonical, String.upcase(wanted))
  end

  defp check_size(%AudiobookRelease{size: nil}), do: :ok

  defp check_size(%AudiobookRelease{size: size}) when size >= @min_size and size <= @max_size,
    do: :ok

  defp check_size(%AudiobookRelease{}), do: {:reject, :size_out_of_band}

  defdelegate tokens(string), to: TitleFold
  defdelegate drop_article(words), to: TitleFold
end
