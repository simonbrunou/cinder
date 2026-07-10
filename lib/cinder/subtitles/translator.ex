defmodule Cinder.Subtitles.Translator do
  @moduledoc false

  @callback translate(cues :: [String.t()], target_language :: String.t()) ::
              {:ok, [String.t()]} | {:error, term()}
end
