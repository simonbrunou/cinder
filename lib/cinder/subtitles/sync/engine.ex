defmodule Cinder.Subtitles.Sync.Engine do
  @moduledoc false

  @type metrics :: %{
          required(:offset_ms) => integer(),
          required(:rate) => float(),
          optional(:score) => number(),
          optional(:reason) => atom(),
          # Piecewise alignments report the segments of the offset function they applied, and
          # the largest absolute shift among them; `offset_ms` above then describes only the
          # single-offset search that preceded the split search.
          optional(:segments) => pos_integer(),
          optional(:max_offset_ms) => non_neg_integer()
        }

  @callback sync(reference :: String.t(), input :: String.t(), output :: String.t()) ::
              {:ok, metrics()} | {:review, metrics()} | {:error, term()}
end
