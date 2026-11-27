defmodule Cinder.ProwlarrHistoryFixtures do
  @moduledoc """
  What Prowlarr 3.1's `HistoryService` writes for a search request Cinder sends (#1859), for the
  parity tests' history entries. It takes the tokens out by hand, apart from
  `Cinder.Indexers.Parity.HistoryMatch`, so a test of the match does not read the code it tests.
  """

  @token ~r/\{(\w+):([^}]*)\}/

  # The tokens `NewznabRequest.QueryToParams` takes out of each type's query, as Cinder sends them.
  @names %{"tvsearch" => ~w(TvdbId Season), "movie" => ~w(ImdbId), "book" => ~w(Author Title)}

  @doc """
  The `{term, ids}` an entry of the request `query` of `type` holds: the query without the
  type's tokens, trimmed, and each token as its history field (`TvdbId` as `"tvdbId"`).
  """
  @spec written(String.t(), String.t()) :: {String.t(), %{String.t() => String.t()}}
  def written(query, type) do
    names = Map.get(@names, type, [])

    ids =
      for [_whole, name, value] <- Regex.scan(@token, query),
          name in names,
          into: %{},
          do: {String.downcase(String.first(name)) <> String.slice(name, 1..-1//1), value}

    term =
      Regex.replace(@token, query, fn whole, name -> if name in names, do: "", else: whole end)

    {String.trim(term), ids}
  end
end
