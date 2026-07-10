defmodule Cinder.Subtitles.Srt do
  @moduledoc false

  @type cue :: %{prefix: binary(), dialogue: binary(), separator: binary()}
  @type t :: %__MODULE__{cues: [cue()]}

  defstruct cues: []

  @cue_separator ~r/\A(.*?)((?:\r?\n){2,}|\z)/s
  @cue ~r/\A(?<prefix>\d+(?:\r?\n)[^\r\n]*-->[^\r\n]*(?:\r?\n))(?<dialogue>[^\r\n]+(?:\r?\n[^\r\n]+)*)(?<ending>\r?\n)?\z/

  @spec parse(binary()) :: {:ok, t()} | {:error, :invalid_srt}
  def parse(srt) when is_binary(srt), do: parse_cues(srt, [])

  @spec dialogue(t()) :: [String.t()]
  def dialogue(%__MODULE__{cues: cues}), do: Enum.map(cues, & &1.dialogue)

  @spec render(t(), [String.t()]) :: binary() | {:error, :cue_count_mismatch}
  def render(%__MODULE__{cues: cues}, translated_cues) when is_list(translated_cues) do
    if length(cues) == length(translated_cues) do
      Enum.map_join(Enum.zip(cues, translated_cues), fn {cue, translated} ->
        cue.prefix <> translated <> cue.separator
      end)
    else
      {:error, :cue_count_mismatch}
    end
  end

  defp parse_cues("", []), do: {:error, :invalid_srt}
  defp parse_cues("", cues), do: {:ok, %__MODULE__{cues: Enum.reverse(cues)}}

  defp parse_cues(srt, cues) do
    case Regex.run(@cue_separator, srt) do
      [_, source_cue, separator] ->
        with {:ok, cue} <- parse_cue(source_cue, separator) do
          consumed = byte_size(source_cue) + byte_size(separator)
          rest = binary_part(srt, consumed, byte_size(srt) - consumed)
          parse_cues(rest, [cue | cues])
        end

      _ ->
        {:error, :invalid_srt}
    end
  end

  defp parse_cue(source_cue, separator) do
    case Regex.named_captures(@cue, source_cue) do
      %{"prefix" => prefix, "dialogue" => dialogue, "ending" => ending} ->
        {:ok, %{prefix: prefix, dialogue: dialogue, separator: ending <> separator}}

      _ ->
        {:error, :invalid_srt}
    end
  end
end
