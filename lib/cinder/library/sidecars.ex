defmodule Cinder.Library.Sidecars do
  @moduledoc """
  Loose subtitle files (`.srt`/`.ass`/…) that ship alongside a downloaded video. On import we
  hardlink or copy each belonging sidecar next to the imported video (renamed to the media-server's
  `<video>.<lang>[.forced].<ext>` convention) so Jellyfin/Plex pick them up, and report their
  languages for storage. Filesystem access goes through `Cinder.Library.Filesystem`.
  """
  require Logger

  alias Cinder.Acquisition.Parser
  alias Cinder.Library
  alias Cinder.Library.PathPolicy
  alias Cinder.Settings

  require Library

  @sub_exts ~w(.srt .ass .ssa .sub .vtt)
  @flags ~w(forced sdh cc hi)
  @video_exts ~w(.mkv .mp4 .avi .m4v .mov .wmv .ts)

  # `hi` is both the hearing-impaired flag and ISO-639-1 Hindi. Read it as a flag when the name
  # carries another language, and as the language when it carries none — otherwise `Movie.hi.srt`
  # is unnameable, since Hindi has no other ISO-639-1 spelling (issue #201). `sdh` is the
  # unambiguous hearing-impaired token and stays a flag always, so preferring the language reading
  # in the conflict loses nothing.
  @ambiguous_flags ~w(hi)

  # iso-alias -> iso1 (e.g. "fra"/"fre"/"fr" -> "fr"), plus full-word names.
  @aliases for {iso1, codes} <- Parser.audio_codes(), code <- codes, into: %{}, do: {code, iso1}
  @names for {iso1, tag} <- Parser.language_tags(), into: %{}, do: {String.downcase(tag), iso1}

  @doc "ISO code from a sidecar filename; flags stripped; unknown/absent -> \"und\"."
  def language(filename), do: filename |> classify() |> elem(0)

  # One decision for both readings, so a `hi` consumed as the language can't ALSO be re-emitted as
  # a flag by link/2 — which would name a Hindi sidecar `<stem>.hi.hi.srt`.
  defp classify(filename) do
    tokens =
      filename
      |> Path.basename()
      |> Path.rootname()
      |> String.split(".")
      |> Enum.map(&String.downcase/1)

    flags = Enum.filter(tokens, &(&1 in @flags))

    case resolve(tokens, @flags) do
      nil -> ambiguous_reading(tokens, flags)
      language -> {language, flags}
    end
  end

  # Nothing resolved with every flag stripped, so retry letting the ambiguous ones be languages.
  # Only reachable when the last non-flag token is itself `hi`, i.e. exactly the shadowed case.
  defp ambiguous_reading(tokens, flags) do
    case resolve(tokens, @flags -- @ambiguous_flags) do
      nil -> {"und", flags}
      language -> {language, flags -- @ambiguous_flags}
    end
  end

  defp resolve(tokens, strip) do
    case tokens |> Enum.reject(&(&1 in strip)) |> List.last() do
      nil -> nil
      token -> @aliases[token] || @names[token]
    end
  end

  @doc "Sidecar files belonging to `source_video` (stem match, or any sub when the folder holds one video)."
  def files(source_video) do
    dir = Path.dirname(source_video)
    roots = source_roots()

    with {:ok, source_video} <-
           path_policy().source_file(source_video, roots, @video_exts, filesystem: fs()),
         true <- fs().dir?(dir),
         {:ok, entries} <- fs().find_files(dir) do
      paths = Enum.map(entries, fn {p, _size} -> p end)
      subs = safe_sidecars(paths, roots)
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

  @doc "Places belonging sidecars next to `dest_video`; returns linked languages (best-effort)."
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

  defp flags_of(path), do: path |> classify() |> elem(1)

  defp do_link(src, dest) do
    with {:ok, src} <-
           path_policy().source_file(src, source_roots(), @sub_exts, filesystem: fs()),
         {:ok, dest} <-
           path_policy().destination(dest, Settings.library_roots(), filesystem: fs()),
         :ok <- link_or_copy(src, dest) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("sidecar link rejected: #{inspect(reason)}")
        :error
    end
  end

  defp link_or_copy(src, dest) do
    case fs().ln(src, dest) do
      {:error, errno} when Library.copy_fallback_errno?(errno) -> copy(src, dest)
      result -> result
    end
  end

  # Copy the sidecar bytes into a temp on the destination filesystem, then land it. Landing is
  # no-replace on purpose: the hardlink path this falls back from could never clobber, and a
  # sidecar that loses a race with a manually-added subtitle must lose it quietly.
  #
  # The temp is the durability seam. `Library`'s video path can land with `cp_exclusive` because a
  # journal recovers a half-written destination; sidecars have no journal, so writing bytes
  # straight to the final path would leave a truncated `.srt` that every later retry then skips
  # with `:eexist`. Copying into `.cinder-tmp-*` first means an interrupted copy only ever leaves
  # a temp, which the next import's `sweep_temps` reclaims.
  defp copy(src, dest) do
    with {:ok, root} <- Settings.library_root_for_path(dest) do
      dir = Path.dirname(dest)
      sweep_temps(dir, root)
      tmp = Path.join(dir, ".cinder-tmp-#{System.unique_integer([:positive])}")

      result =
        with {:ok, ^tmp} <- safe_destination(tmp, root),
             :ok <- fs().cp(src, tmp),
             {:ok, ^tmp} <- safe_destination(tmp, root),
             {:ok, ^dest} <- safe_destination(dest, root),
             do: land_noreplace(tmp, dest)

      _ = safe_remove(tmp, root)
      result
    end
  end

  # `link(2)` is the no-replace primitive. On a mount with no hardlink support at all the temp
  # can't be linked either, so fall back to an exclusive copy — which is safe *here* precisely
  # because the source is the completed temp, not the original: a failed exclusive copy leaves a
  # partial destination only if the destination did not already exist, and the temp it copies from
  # is whole.
  defp land_noreplace(tmp, dest) do
    case fs().ln(tmp, dest) do
      {:error, errno} when Library.copy_fallback_errno?(errno) ->
        fs().cp_exclusive(tmp, dest, fn _stat -> :ok end)

      result ->
        result
    end
  end

  defp safe_sidecars(paths, roots) do
    paths
    |> Enum.filter(&(String.downcase(Path.extname(&1)) in @sub_exts))
    |> Enum.flat_map(fn path ->
      case path_policy().source_file(path, roots, @sub_exts, filesystem: fs()) do
        {:ok, safe_path} -> [safe_path]
        {:error, :unsafe_source} -> []
      end
    end)
  end

  defp source_roots, do: Enum.uniq(Settings.import_roots() ++ Settings.library_roots())

  defp safe_destination(path, root),
    do: path_policy().destination(path, root, filesystem: fs())

  # Reclaims temps left by an interrupted copy, so a crashed import can't strand bytes here.
  defp sweep_temps(dir, root) do
    case path_policy().walk(dir, roots: [root], filesystem: fs()) do
      {:ok, files} ->
        for {path, _size} <- files,
            String.contains?(Path.basename(path), ".cinder-tmp-"),
            do: safe_remove(path, root)

      _ ->
        :ok
    end
  end

  defp safe_remove(path, root) do
    with :ok <- path_policy().deletable_file(path, [root], filesystem: fs()),
         do: fs().rm(path)
  end

  defp fs, do: Application.get_env(:cinder, :filesystem)
  defp path_policy, do: Application.get_env(:cinder, :path_policy, PathPolicy)
end
