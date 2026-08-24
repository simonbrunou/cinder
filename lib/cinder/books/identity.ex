defmodule Cinder.Books.Identity do
  @moduledoc """
  Resolves a query to exactly one provider work, or explains why it cannot.

  The parity contract's order is durable provider identity first, then conservative title and
  contributor evidence. A `"<provider>:work:<foreign_id>"` query takes the first path and is an
  exact fetch; anything else is searched across `Cinder.Books.Metadata.providers/0` in order,
  stopping at the first provider with a reliable answer.

  ## Why the matcher is this small

  "A title, ISBN, ASIN, path, or filename alone is insufficient for automatic identity
  resolution." So the bar is deliberately blunt:

  1. A candidate is **eligible** only if one of its contributor names appears in the query, as a
     token set rather than a substring — "Cixin Liu" and "Liu Cixin" are the same person, and
     given-name-last conventions are not an edge case. No contributor evidence, no candidate; this
     alone rules out every first-fuzzy-result failure, the one outcome the contract forbids
     outright.
  2. Subtract the matched contributor tokens from the query; whatever is left is the title the
     caller meant. It must equal the candidate title exactly, after folding case, diacritics,
     punctuation, a leading article, and format noise.
  3. Survivors are ordered by the provider's own edition count, then by foreign id so the choice
     is deterministic rather than dependent on result order.

  There is no separate `:ambiguous` outcome, because steps 1 and 2 make it unreachable: every
  survivor already carries the same folded title *and* a matching contributor, so a tie is two
  provider rows for one work (Open Library has several), never two different works. The genuinely
  ambiguous inputs the contract worries about — a bare title, a wrong author, an omnibus against
  its parts — are rejected at step 1 or 2 and come back `{:unresolved, :no_reliable_match}`.

  Measured against the frozen fixtures this clears the contract's bar — 36 of 40 resolved against
  a >= 90% threshold, with the three cases the contract requires to stay unresolved staying
  unresolved. `Cinder.Books.CorpusB2bTest` pins that, and names the two cases where this matcher
  and the fixture's own labelling disagree along with why.
  """
  require Logger

  alias Cinder.Books.Metadata

  @type resolution :: %{work: Metadata.work(), provider: atom(), evidence: map()}

  @type result ::
          {:ok, resolution()}
          | {:unresolved, atom()}
          | {:error, :providers_unavailable}

  # Words a release or a requester adds that never belong to the work title itself.
  @noise ~w(omnibus ebook e book audiobook audio unabridged abridged edition editions)
  @articles ~w(the a an le la les el los der die das)

  @doc """
  Resolves `query` against the configured providers.

  `query` is either a durable reference (`"openlibrary:work:OL50548W"`) or free text
  (`"Beloved Toni Morrison"`).
  """
  @spec resolve(String.t()) :: result()
  def resolve(query) when is_binary(query) do
    case reference(query) do
      {:ok, provider_module, foreign_id} -> fetch(provider_module, foreign_id)
      :error -> search_providers(Metadata.providers(), query, [])
    end
  end

  @doc "Formats a work reference the way `resolve/1` parses it."
  @spec reference_for(atom(), String.t()) :: String.t()
  def reference_for(provider, foreign_id), do: "#{provider}:work:#{foreign_id}"

  defp reference(query) do
    with [provider, "work", foreign_id] <- String.split(query, ":", parts: 3),
         module when not is_nil(module) <- provider_module(provider) do
      {:ok, module, foreign_id}
    else
      _other -> :error
    end
  end

  defp provider_module(name),
    do: Enum.find(Metadata.providers(), &(to_string(&1.provider()) == name))

  defp fetch(provider_module, foreign_id) do
    case provider_module.get_work(foreign_id) do
      {:ok, work} ->
        {:ok,
         %{
           work: work,
           provider: provider_module.provider(),
           evidence: %{strategy: :provider_reference, candidates_considered: 1}
         }}

      {:error, _reason} ->
        {:error, :providers_unavailable}
    end
  end

  # Walks the providers in order. `answered?` distinguishes "every provider was down" from
  # "providers answered and none of the answers was good enough" — the refresher must not treat
  # an outage as a metadata change.
  defp search_providers([], _query, answers) do
    if Enum.any?(answers, & &1),
      do: {:unresolved, :no_reliable_match},
      else: {:error, :providers_unavailable}
  end

  defp search_providers([provider_module | rest], query, answers) do
    case provider_module.search(query) do
      {:ok, candidates} ->
        case select(candidates, query) do
          {:ok, candidate, evidence} -> fetch_selected(provider_module, candidate, evidence)
          :none -> search_providers(rest, query, [true | answers])
        end

      {:error, reason} ->
        Logger.info("books identity: #{inspect(provider_module)} unavailable: #{inspect(reason)}")
        search_providers(rest, query, [false | answers])
    end
  end

  defp fetch_selected(provider_module, candidate, evidence) do
    case provider_module.get_work(candidate.foreign_id) do
      {:ok, work} -> {:ok, %{work: work, provider: candidate.provider, evidence: evidence}}
      {:error, _reason} -> {:error, :providers_unavailable}
    end
  end

  @doc false
  # Public only so the corpus test can exercise the matcher against frozen candidate lists
  # without standing up a provider.
  @spec select([Metadata.candidate()], String.t()) ::
          {:ok, Metadata.candidate(), map()} | :none
  def select(candidates, query) do
    query_tokens = tokens(query)

    candidates
    |> Enum.flat_map(&score(&1, query_tokens))
    |> Enum.sort_by(fn {candidate, _matched} ->
      {-candidate.edition_count, candidate.foreign_id}
    end)
    |> best(length(candidates))
  end

  defp best([], _considered), do: :none

  defp best([{candidate, matched} | _rest], considered) do
    {:ok, candidate,
     %{
       strategy: :title_and_contributor,
       contributors_matched: matched,
       candidates_considered: considered
     }}
  end

  # Eligible when at least one contributor's tokens are all present in the query AND the query
  # minus those tokens is exactly the candidate title.
  defp score(candidate, query_tokens) do
    {remainder, matched} =
      Enum.reduce(candidate.contributors, {query_tokens, []}, fn contributor, {rest, matched} ->
        name = tokens(contributor.name)

        # `--` removes one occurrence per token, so a query naming two people who share a surname
        # does not let one name consume the other's.
        if name != [] and name -- rest == [] do
          {rest -- name, [contributor.name | matched]}
        else
          {rest, matched}
        end
      end)

    if matched != [] and title_key(remainder) == title_key(tokens(candidate.title)) do
      [{candidate, Enum.reverse(matched)}]
    else
      []
    end
  end

  # Fold to comparable tokens: NFD-decompose so "Misérables" matches "Miserables", drop everything
  # that isn't a letter or digit, and split. (`Cinder.Acquisition` folds release titles the same
  # way; that copy is private and tuned for scene naming, so books keeps its own.)
  defp tokens(string) do
    string
    |> nfd()
    |> String.downcase()
    |> String.replace(~r/['’]/u, "")
    |> String.replace(~r/[^\x00-\x7f]/u, "")
    |> String.split(~r/[^a-z0-9]+/, trim: true)
  end

  # NFD first, and not just for the diacritic fold: the regexes below raise on malformed UTF-8,
  # and a garbled query must never raise out of a resolver the refresher calls in a loop.
  # :unicode.characters_to_nfd_binary hands back the decodable prefix as {:error | :incomplete,
  # ok_part, rest}, which is the most of the input that can be matched on at all.
  defp nfd(string) do
    case :unicode.characters_to_nfd_binary(string) do
      binary when is_binary(binary) -> binary
      {_kind, ok_part, _rest} -> ok_part
    end
  end

  # Drop a leading article and format noise before comparing — "The Little Prince" and Open
  # Library's "Little Prince" are the same work, and "... omnibus" is a requester's annotation.
  defp title_key(words) do
    words
    |> Enum.reject(&(&1 in @noise))
    |> drop_article()
    |> Enum.join(" ")
  end

  defp drop_article([article | rest]) when rest != [],
    do: if(article in @articles, do: rest, else: [article | rest])

  defp drop_article(words), do: words
end
