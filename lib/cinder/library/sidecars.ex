defmodule Cinder.Library.Sidecars do
  @moduledoc """
  Loose subtitle files (`.srt`/`.ass`/…) that ship alongside a downloaded video. On import we
  hardlink each belonging sidecar next to the imported video (renamed to the media-server's
  `<video>.<lang>[.forced].<ext>` convention) so Jellyfin/Plex pick them up, and report their
  languages for storage. Filesystem access goes through `Cinder.Library.Filesystem`.
  """
  require Logger

  alias Cinder.Acquisition.Parser

  @sub_exts ~w(.srt .ass .ssa .sub .vtt)
  @flags ~w(forced sdh cc hi)
  @video_exts ~w(.mkv .mp4 .avi .m4v .mov .wmv .ts)

  # iso-alias -> iso1 (e.g. "fra"/"fre"/"fr" -> "fr"), plus full-word names.
  @aliases for {iso1, codes} <- Parser.audio_codes(), code <- codes, into: %{}, do: {code, iso1}
  @names for {iso1, tag} <- Parser.language_tags(), into: %{}, do: {String.downcase(tag), iso1}

  @doc "ISO code from a sidecar filename; flags stripped; unknown/absent -> \"und\"."
  def language(filename) do
    tokens =
      filename
      |> Path.basename()
      |> Path.rootname()
      |> String.split(".")
      |> Enum.map(&String.downcase/1)
      |> Enum.reject(&(&1 in @flags))

    case List.last(tokens) do
      nil -> "und"
      tok -> @aliases[tok] || @names[tok] || "und"
    end
  end

  @doc "Sidecar files belonging to `source_video` (stem match, or any sub when the folder holds one video)."
  def files(source_video) do
    dir = Path.dirname(source_video)

    with true <- fs().dir?(dir),
         {:ok, entries} <- fs().find_files(dir) do
      paths = Enum.map(entries, fn {p, _size} -> p end)
      subs = Enum.filter(paths, &(String.downcase(Path.extname(&1)) in @sub_exts))
      stem = Path.rootname(Path.basename(source_video))
      lone_video? = Enum.count(paths, &(String.downcase(Path.extname(&1)) in @video_exts)) == 1

      subs
      |> Enum.filter(fn p ->
        lone_video? or
          String.starts_with?(String.downcase(Path.basename(p)), String.downcase(stem) <> ".")
      end)
      |> Enum.map(fn p -> {p, language(p)} end)
    else
      _ -> []
    end
  end

  @doc "SRT sidecars belonging to `source_video`, for the translation source fallback."
  def srt_files(source_video) do
    Enum.filter(files(source_video), fn {path, _language} ->
      String.downcase(Path.extname(path)) == ".srt"
    end)
  end

  @doc "Hardlinks belonging sidecars next to `dest_video`; returns linked languages (best-effort)."
  def link(source_video, dest_video) do
    dest_stem = Path.rootname(dest_video)

    langs =
      for {path, lang} <- files(source_video),
          do_link(path, dest_dir_name(dest_stem, path, lang)) == :ok do
        lang
      end

    Enum.uniq(langs)
  end

  defp dest_dir_name(dest_stem, src_path, lang) do
    flag = src_path |> flags_of() |> Enum.map_join(&".#{&1}")
    "#{dest_stem}.#{lang}#{flag}#{String.downcase(Path.extname(src_path))}"
  end

  defp flags_of(path) do
    path
    |> Path.basename()
    |> Path.rootname()
    |> String.split(".")
    |> Enum.map(&String.downcase/1)
    |> Enum.filter(&(&1 in @flags))
  end

  defp do_link(src, dest) do
    case fs().ln(src, dest) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("sidecar link failed #{src} -> #{dest}: #{inspect(reason)}")
        :error
    end
  end

  defp fs, do: Application.get_env(:cinder, :filesystem)
end
