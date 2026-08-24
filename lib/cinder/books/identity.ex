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
     caller meant. It must equal the candidate title after folding case, diacritics, punctuation
     and a leading article — exactly (strength 0), or once the requester's format annotations
     come off (strength 1).

     **Annotations come off the query only, never off the provider's title, and only from its
     leading and trailing edges.** Stripping both sides is what let "The Audio Book" resolve to a
     different work called "The Book"; stripping mid-string did the same for "The Audiobook
     Murders" and "The Murders". An annotation is something a requester appends, so only the
     edges can hold one. An exact match outranks an annotation-stripped one, so when both works
     are candidates the requester gets the one they actually named.
  3. A candidate whose title folds away to nothing is rejected outright — see `score/2`.
  4. Survivors are ordered by match strength, then by the provider's own edition count, then by
     foreign id so the choice is deterministic rather than dependent on result order.

  There is no separate `:ambiguous` outcome. In practice a survivor set larger than one is Open
  Library's several rows for a single work — the corpus's `chronicles-of-narnia` is exactly that,
  and the edition-count order resolves it correctly. The inputs the contract actually worries
  about — a bare title, an author with no title, a wrong author, an omnibus against its parts —
  are rejected at steps 1–3 and come back `{:unresolved, :no_reliable_match}`, which is the
  outcome the contract prefers anyway.

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

  # Format annotations a requester appends to a query. The bar for membership is high — a word
  # here has to be one no book would carry as an ordinary title word — because every entry is a
  # chance to collide two different works. `book` taught that lesson (it was here to absorb
  # "e-book", and it made "The Book Thief" and "The Thief" identical); `audio`, `edition`,
  # `editions`, `abridged` and `unabridged` came out for the same reason before they could, each
  # of them folding a real title into a different work's:
  #
  #     "The Audio Book" → "The Book",  "First Edition" → "First",  "An Abridged Life" → "A Life"
  #
  # Only `omnibus` has corpus support (`lord-of-the-rings`); the other two are unambiguous.
  @annotations ~w(omnibus ebook audiobook)
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
    |> Enum.sort_by(fn {candidate, _matched, strength} ->
      {strength, -candidate.edition_count, candidate.foreign_id}
    end)
    |> best(length(candidates))
  end

  defp best([], _considered), do: :none

  defp best([{candidate, matched, _strength} | _rest], considered) do
    {:ok, candidate,
     %{
       strategy: :title_and_contributor,
       contributors_matched: matched,
       candidates_considered: considered
     }}
  end

  # Eligible when at least one contributor's tokens are all present in the query AND the query
  # minus those tokens is the candidate title — exactly, or once annotations come off.
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

    title = title_key(tokens(candidate.title))
    matched = Enum.reverse(matched)

    # `title != ""` is load-bearing, not defensive. Folding strips non-ASCII, so a title written
    # entirely in Japanese/Chinese/Cyrillic folds to "" — and so does a query that named only an
    # author. Without this, "Haruki Murakami" matched every one of his non-Latin-titled works and
    # the edition-count order silently returned the biggest: a first-result selection by another
    # name, on an input weaker than the bare title the contract already rejects. A title we cannot
    # fold is a title we cannot compare, so it is unresolved rather than assumed.
    cond do
      matched == [] or title == "" -> []
      title_key(remainder) == title -> [{candidate, matched, 0}]
      title_key(trim_annotations(remainder)) == title -> [{candidate, matched, 1}]
      true -> []
    end
  end

  # An annotation is *appended or prepended* to a query — "... omnibus", "audiobook: ..." — never
  # embedded in the middle of a title. Trimming only the edges is what separates the two, and it
  # is why "The Audiobook Murders" no longer resolves to a different work called "The Murders".
  #
  # It also makes the trim candidate-independent. The previous rule stripped a word whenever the
  # candidate's own title lacked it, so every candidate reshaped the query in its own favour and
  # "the title the requester meant" was not one string but one per candidate. Now they are all
  # judged against the same two.
  #
  # Never trims to nothing: *Omnibus* is a real title, and the strength-0 pass matches it anyway.
  defp trim_annotations(words) do
    words |> trim_leading() |> Enum.reverse() |> trim_leading() |> Enum.reverse()
  end

  defp trim_leading([word | rest]) when rest != [] do
    if word in @annotations, do: trim_leading(rest), else: [word | rest]
  end

  defp trim_leading(words), do: words

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

  # Drop a leading article before comparing — "The Little Prince" and Open Library's
  # "Little Prince" are the same work.
  defp title_key(words), do: words |> drop_article() |> Enum.join(" ")

  defp drop_article([article | rest]) when rest != [],
    do: if(article in @articles, do: rest, else: [article | rest])

  defp drop_article(words), do: words
end
