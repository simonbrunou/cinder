defmodule Cinder.RepoWatch.Hold do
  @moduledoc """
  An open transaction as `Cinder.RepoWatch` tracks it in the querying process's dictionary, from
  BEGIN's return to COMMIT's or ROLLBACK's: when the hold started on the watch's clock, BEGIN's
  own time, and the query time of the statements run inside so far, all in milliseconds.
  """

  @enforce_keys [:start, :begin]
  defstruct start: nil, begin: nil, sql: 0

  @type t :: %__MODULE__{start: integer(), begin: non_neg_integer(), sql: non_neg_integer()}
end
