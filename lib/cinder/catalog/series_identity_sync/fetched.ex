defmodule Cinder.Catalog.SeriesIdentitySync.Fetched do
  @moduledoc """
  What `Cinder.Catalog.SeriesIdentitySync.fetch/3` read from TMDB before the caller's
  transaction, for the caller's tree write and for `SeriesIdentitySync.sync/2`.

    * `seasons`: each season with its episodes, their titles in every other locale under
      `:localizations`.
    * `identity`: the series' TMDB aliases (`aliases`), its type-2 episode groups
      (`absolute_groups`), the detail of its scene group or `nil` (`scene_group_detail`), and the
      scene group id that detail was fetched for (`scene_group_fetched_for`).
  """

  @enforce_keys [:seasons, :identity]
  defstruct [:seasons, :identity]

  @type t :: %__MODULE__{seasons: [map()], identity: map()}
end
