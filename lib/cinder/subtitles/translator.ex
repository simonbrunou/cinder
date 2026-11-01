defmodule Cinder.Subtitles.Translator do
  @moduledoc false

  @callback translate(cues :: [String.t()], target_language :: String.t()) ::
              {:ok, [String.t()]} | {:error, term()}

  # Whether `translate/2` can run at all. `Cinder.Subtitles` reads the whole video file to get a
  # translation source, so it asks first (#861).
  @callback configured?() :: boolean()
end
