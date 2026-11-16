defmodule Cinder.Acquisition.BookSearch.NormalizedWork do
  @moduledoc """
  The work a book search runs and a `Cinder.Acquisition.BookScorer` judges against, after
  `Cinder.Acquisition.BookSearch` has read it out of a `Cinder.Books.Work` or a plain map.

    * `title` — the work's title.
    * `authors` — the display names of its authors.
    * `identifiers` — the identifiers to probe, in probe order. The search caps how many it
      probes.
    * `series` — the series the work belongs to, as names or as `%{name: ...}` maps.

  Each list defaults to `[]`, as normalization gives for a field the input lacks.

  `BookSearch` returns a value of this struct unchanged when asked to normalize it again. A plain
  map carries its identifiers under the plan's `identifiers_key` (`:isbns` for the e-book plan),
  while this struct carries them under `identifiers`. For the e-book plan, reading a normalized
  value as a plain map would look under `:isbns` and drop every identifier probe, so the struct
  is how `BookSearch` tells the two apart.
  """

  @enforce_keys [:title]
  defstruct [:title, authors: [], identifiers: [], series: []]

  @type t :: %__MODULE__{
          title: String.t(),
          authors: [String.t()],
          identifiers: [String.t()],
          series: [String.t() | map()]
        }
end
