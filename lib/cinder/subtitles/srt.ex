defmodule Cinder.Subtitles.Srt do
  @moduledoc false

  @type cue :: %{prefix: binary(), dialogue: binary(), separator: binary()}
  @type t :: %__MODULE__{bom: binary(), cues: [cue()]}

  defstruct bom: "", cues: []

  @bom <<0xEF, 0xBB, 0xBF>>
  @cue_separator ~r/\A(.*?)((?:\r?\n){2,}|\z)/s
  @cue ~r/\A(?<prefix>\d+(?:\r?\n)[^\r\n]*-->[^\r\n]*(?:\r?\n))(?<dialogue>[^\r\n]+(?:\r?\n[^\r\n]+)*)(?<ending>\r?\n)?\z/

  @spec parse(binary()) :: {:ok, t()} | {:error, :invalid_srt}
  def parse(@bom <> srt), do: parse_cues(srt, [], @bom)
  def parse(srt) when is_binary(srt), do: parse_cues(srt, [], "")

  @spec dialogue(t()) :: [String.t()]
  def dialogue(%__MODULE__{cues: cues}), do: Enum.map(cues, & &1.dialogue)

  @spec render(t(), [String.t()]) :: binary() | {:error, :cue_count_mismatch}
  def render(%__MODULE__{bom: bom, cues: cues}, translated_cues) when is_list(translated_cues) do
    if length(cues) == length(translated_cues) do
      bom <>
        Enum.map_join(Enum.zip(cues, translated_cues), fn {cue, translated} ->
          cue.prefix <> translated <> cue.separator
        end)
    else
      {:error, :cue_count_mismatch}
    end
  end

  defp parse_cues("", [], _bom), do: {:error, :invalid_srt}
  defp parse_cues("", cues, bom), do: {:ok, %__MODULE__{bom: bom, cues: Enum.reverse(cues)}}

  defp parse_cues(srt, cues, bom) do
    case Regex.run(@cue_separator, srt) do
      [_, source_cue, separator] ->
        with {:ok, cue} <- parse_cue(source_cue, separator) do
          consumed = byte_size(source_cue) + byte_size(separator)
          rest = binary_part(srt, consumed, byte_size(srt) - consumed)
          parse_cues(rest, [cue | cues], bom)
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
