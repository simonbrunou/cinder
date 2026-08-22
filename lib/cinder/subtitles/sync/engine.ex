defmodule Cinder.Subtitles.Sync.Engine do
  @moduledoc false

  @type metrics :: %{
          required(:offset_ms) => integer(),
          required(:rate) => float(),
          optional(:score) => number(),
          optional(:split_count) => non_neg_integer(),
          optional(:reason) => atom()
        }

  @callback sync(reference :: String.t(), input :: String.t(), output :: String.t()) ::
              {:ok, metrics()} | {:review, metrics()} | {:error, term()}
end
