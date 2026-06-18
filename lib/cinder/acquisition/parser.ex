defmodule Cinder.Acquisition.Parser do
  @moduledoc """
  Extracts release attributes (`resolution`, `codec`, `group`, `language`) from a
  release name. Pure and best-effort: an unrecognized field is `nil`.

  `size` is intentionally not parsed here — it comes from the indexer's reported
  byte count (see `Cinder.Acquisition`).
  """

  @resolutions ["2160p", "1080p", "720p", "480p"]

  @codecs [
    {~r/x265/i, "x265"},
    {~r/h\.?265/i, "h265"},
    {~r/hevc/i, "h265"},
    {~r/x264/i, "x264"},
    {~r/h\.?264/i, "h264"},
    {~r/avc/i, "h264"},
    {~r/av1/i, "av1"},
    {~r/xvid/i, "xvid"}
  ]

  @languages [
    {~r/\bmulti\b/i, "MULTI"},
    {~r/\bfrench\b/i, "FRENCH"},
    {~r/\bgerman\b/i, "GERMAN"},
    {~r/\bspanish\b/i, "SPANISH"},
    {~r/\bitalian\b/i, "ITALIAN"}
  ]

  @doc """
  Parses `name` into `%{resolution, codec, group, language}`. Each value is `nil`
  when no known token matches.
  """
  def parse(name) when is_binary(name) do
    %{
      resolution: resolution(name),
      codec: first_match(name, @codecs),
      group: group(name),
      language: first_match(name, @languages)
    }
  end

  defp resolution(name) do
    down = String.downcase(name)
    Enum.find(@resolutions, &String.contains?(down, &1))
  end

  defp first_match(name, table) do
    Enum.find_value(table, fn {pattern, value} -> if Regex.match?(pattern, name), do: value end)
  end

  # The trailing "-TOKEN", but only when TOKEN is a single alphanumeric run (no
  # dots/spaces), after stripping a container extension. Otherwise nil — so a
  # hyphenated title ("Spider-Man") or a source token ("WEB-DL.H264") is never read
  # as a group. See the spec for the two accepted, bounded edge cases.
  defp group(name) do
    stripped = Regex.replace(~r/\.(mkv|mp4|avi|m4v|ts)$/i, name, "")

    case Regex.run(~r/-([A-Za-z0-9]+)$/, stripped) do
      [_, group] -> group
      nil -> nil
    end
  end
end
