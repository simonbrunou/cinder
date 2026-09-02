defmodule Cinder.Library.AudiobookSources do
  @moduledoc """
  Resolves a completed audiobook download to an *ordered list* of accepted files, or an explained
  refusal — the `Cinder.Library.BookSources` sibling for multi-track audio.

  Reuses `Cinder.Library.safe_walk/1`, `Cinder.Library.BookArchive.{Zip,Rar}` (unchanged), and
  `Cinder.Library.path_policy()` exactly as `BookSources` does: the containment, symlink-refusal,
  and archive-entry/size-ceiling guarantees are identical infrastructure, not reimplemented here.
  The one real change to shared infrastructure is `BookArchive.extract_and_resolve/3` (arity grew
  from 2 to thread `opts` to the extractors) — see its own moduledoc; this module is the one
  caller that raises `max_expanded_size` to the audiobook profile's own 8 GB ceiling
  (`Cinder.Acquisition.AudiobookScorer.size_band/0`) rather than the e-book-tuned 1 GB extractor
  default.

  ## Pipeline

  1. **Extraction** — identical to `BookSources.resolve/1`'s archive handling (one archive, or
     none), recursing into an extracted scratch directory exactly once.
  2. **Candidate collection** — every `.m4b`/`.mp3` file is a candidate. A stray *other audio*
     file (`.m4a`/`.aac`/`.flac`/`.ogg`/`.wma`) alongside at least one accepted candidate is never
     silently ignored: `safe_source/1`'s own extension allow-list refuses it as `:unsafe_source`,
     the same reason an e-book import already uses for "not one of the accepted formats" — no new
     rejection atom needed. `.nfo`/`.jpg`/`.txt`-style non-audio padding stays invisible, as it
     already is for e-books.
  3. **Format-magic verification** — an `ID3`/MPEG-frame-sync check for `.mp3`, an `ftyp` box
     check for `.m4b` — the same positive-identification discipline
     `BookSources.verify_magic/2` already applies, needing no subprocess.
  4. **Mixed-book detection** — a filename-stem check (always) and an embedded-tag check (only
     when `Cinder.Library.AudioProbe` is configured and answers) must both pass.
  5. **Deterministic ordering** — embedded tags first, filename-embedded numbers second, and a
     multi-file set with neither is refused rather than guessed.
  6. **Container consistency** — every resolved candidate shares one accepted format; a set
     mixing `.m4b` and `.mp3` is refused, since an audiobook's tracks are sequential parts, not
     interchangeable copies of each other the way `BookSources`' multi-format e-book collapse
     treats an EPUB + MOBI pair.

  See the B7b plan (`docs/plans/2026-09-02-books-b7-audiobooks.md`, `## B7b`, §2) for the full
  reasoning behind each refusal.
  """

  alias Cinder.Acquisition.AudiobookScorer
  alias Cinder.Library
  alias Cinder.Library.BookArchive

  import Bitwise

  @accepted_extensions ~w(.m4b .mp3)
  @accepted_formats [:m4b, :mp3]

  # Recognized-but-not-accepted audio containers — `Cinder.Acquisition.AudiobookParser`'s own
  # recognized-but-rejected audio vocabulary, minus the e-book formats it also recognizes (those
  # are a different mixed-folder shape, `:unsupported_archive`'s territory, not this list's).
  @other_audio_extensions ~w(.m4a .aac .flac .ogg .wma)

  @archive_extensions ~w(.rar .zip .7z .gz .bz2 .xz .tar .cbz .cbr)
  @extractable_extensions ~w(.zip .cbz .rar .cbr)

  @type resolved_track :: %{
          path: String.t(),
          format: :m4b | :mp3,
          track_number: pos_integer() | nil,
          disc_number: pos_integer() | nil,
          duration_seconds: non_neg_integer() | nil,
          chapter_count: non_neg_integer() | nil,
          order_disc: pos_integer()
        }

  @doc "The file extensions an audiobook import accepts, most-preferred format first."
  @spec accepted_extensions() :: [String.t()]
  def accepted_extensions, do: @accepted_extensions

  @doc """
  The book equivalent of `Cinder.Library.BookSources.safe_source/1`, against the audiobook
  extension allow-list.
  """
  @spec safe_source(String.t()) :: {:ok, String.t()} | {:error, term()}
  def safe_source(path), do: Library.safe_source_file(path, @accepted_extensions)

  @doc """
  Vets the destination DIRECTORY of a track placement before it is created — the same
  `BookSources.safe_destination/2` shape, earlier than staging, for the same reason: if
  `audiobooks/Author` is a symlink pointing outside the library, `mkdir_p` would create
  `outside/Title` and only then would staging reject the path.
  """
  @spec safe_destination(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def safe_destination(path, root),
    do: Library.path_policy().destination(path, root, filesystem: fs())

  @doc """
  Resolves `path` — a completed download's file or directory — to `{:ok, ordered_tracks}`, most
  authoritative-first, or an explained refusal.
  """
  @spec resolve(String.t()) ::
          {:ok, [resolved_track()]}
          | {:error,
             :no_book_file
             | :unsafe_source
             | :unsupported_archive
             | :format_mismatch
             | :mixed_book_filenames
             | :mixed_book_tags
             | :track_order_unknown
             | :track_order_contradictory
             | :container_mismatch
             | term()}
  def resolve(path), do: resolve(path, true)

  # `extract?` bounds recursion to exactly one archive-extraction attempt — see
  # `Cinder.Library.BookSources.resolve/2`'s identical shape and reasoning.
  defp resolve(path, extract?) do
    case Library.safe_walk(path) do
      {:ok, files} -> resolve_folder(files, extract?)
      {:error, :enotdir} -> resolve_file(path, extract?)
      {:error, _reason} = error -> error
    end
  end

  defp resolve_folder(files, extract?) do
    all_paths = Enum.map(files, &elem(&1, 0))
    paths = if extract?, do: Enum.reject(all_paths, &scratch_path?/1), else: all_paths

    case archive_candidate(paths) do
      {:ok, archive_path} when extract? ->
        BookArchive.extract_and_resolve(archive_path, &resolve(&1, false),
          max_expanded_size: max_expanded_size()
        )

      {:ok, _archive_path} ->
        {:error, :unsupported_archive}

      :none ->
        collect_and_order(paths)

      {:error, _reason} = error ->
        error
    end
  end

  defp resolve_file(path, extract?) do
    cond do
      extractable_archive?(path) and extract? ->
        BookArchive.extract_and_resolve(path, &resolve(&1, false),
          max_expanded_size: max_expanded_size()
        )

      archive_file?(path) ->
        {:error, :unsupported_archive}

      true ->
        collect_and_order([path])
    end
  end

  defp max_expanded_size, do: AudiobookScorer.size_band() |> elem(1)

  defp scratch_path?(path), do: BookArchive.scratch_dir_name() in Path.split(path)

  # Identical shape/reasoning to `BookSources.archive_candidate/1` — copied, not shared, per the
  # B7b plan's own "copy the pattern" call for genuinely different domains.
  defp archive_candidate(paths) do
    archives = Enum.filter(paths, &archive_file?/1)
    non_archives = paths -- archives

    cond do
      archives == [] -> :none
      non_archives != [] -> {:error, :unsupported_archive}
      true -> pick_archive(archives)
    end
  end

  defp pick_archive(archives) do
    mains = Enum.filter(archives, &rar_main?/1)
    zips = Enum.filter(archives, &zip_like?/1)
    volumes = (archives -- mains) -- zips

    cond do
      zips == [] and length(mains) == 1 and Enum.all?(volumes, &rar_volume?/1) ->
        {:ok, hd(mains)}

      mains == [] and volumes == [] and length(zips) == 1 ->
        {:ok, hd(zips)}

      true ->
        {:error, :unsupported_archive}
    end
  end

  defp extractable_archive?(path),
    do: String.downcase(Path.extname(path)) in @extractable_extensions

  defp zip_like?(path), do: String.downcase(Path.extname(path)) in ~w(.zip .cbz)
  defp rar_main?(path), do: String.downcase(Path.extname(path)) in ~w(.rar .cbr)
  defp rar_volume?(path), do: Regex.match?(~r/^\.r\d{2}$/u, String.downcase(Path.extname(path)))

  defp archive_file?(path),
    do: String.downcase(Path.extname(path)) in @archive_extensions or rar_volume?(path)

  # --- candidate collection, magic, mixed-book detection, ordering, container consistency ---

  defp collect_and_order(paths) do
    accepted = Enum.filter(paths, &accepted_file?/1)
    other_audio = Enum.filter(paths, &other_audio_file?/1)

    cond do
      accepted == [] -> {:error, :no_book_file}
      # A stray unaccepted-format audio file is never silently dropped from the candidate set —
      # `safe_source/1`'s allow-list refuses it, the same `:unsafe_source` an e-book import
      # already reports for a file outside its own accepted formats.
      other_audio != [] -> {:error, :unsafe_source}
      true -> validate_and_order(accepted)
    end
  end

  defp accepted_file?(path), do: String.downcase(Path.extname(path)) in @accepted_extensions

  defp other_audio_file?(path),
    do: String.downcase(Path.extname(path)) in @other_audio_extensions

  defp validate_and_order(candidates) do
    with :ok <- verify_all_magic(candidates) do
      tracks = Enum.map(candidates, &build_track/1)

      with :ok <- check_mixed_filenames(tracks),
           :ok <- check_mixed_tags(tracks),
           {:ok, ordered} <- order_tracks(tracks),
           :ok <- check_container(ordered) do
        {:ok, finalize(ordered)}
      end
    end
  end

  defp verify_all_magic(candidates) do
    Enum.reduce_while(candidates, :ok, fn path, :ok ->
      case verify_magic(path, format(path)) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # `ID3` (the near-universal tag header) or a raw MPEG frame sync (`0xFF` followed by three set
  # high bits) for MP3; an `ftyp` box at offset 4 naming one of the three real-world M4B/MP4
  # major brands for M4B — the same positive-identification discipline
  # `BookSources.verify_magic/2` already applies.
  defp verify_magic(path, format) do
    case fs().read_prefix(path, 12) do
      {:ok, prefix} -> if magic?(prefix, format), do: :ok, else: {:error, :format_mismatch}
      {:error, _reason} -> {:error, :format_mismatch}
    end
  end

  defp magic?(<<"ID3", _rest::binary>>, :mp3), do: true

  defp magic?(<<0xFF, b1, _rest::binary>>, :mp3) when band(b1, 0xE0) == 0xE0, do: true

  defp magic?(<<_size::binary-size(4), "ftyp", brand::binary-size(4), _rest::binary>>, :m4b)
       when brand in ["M4B ", "mp42", "isom"],
       do: true

  defp magic?(_prefix, _format), do: false

  defp build_track(path) do
    format = format(path)

    %{
      path: path,
      format: format,
      stem: filename_stem(path),
      filename_track: filename_track_number(path),
      filename_disc: filename_disc_number(path),
      probe: probe_track(path)
    }
  end

  defp format(path) do
    extension = String.downcase(Path.extname(path))
    Enum.find(@accepted_formats, &(".#{&1}" == extension))
  end

  defp probe_track(path) do
    case audio_probe() do
      nil ->
        nil

      mod ->
        case mod.probe(path) do
          {:ok, result} -> result
          {:error, _reason} -> nil
        end
    end
  end

  defp audio_probe, do: Application.fetch_env!(:cinder, :audio_probe)

  # Lowercased, separator-collapsed basename with every track-number idiom stripped
  # (`track 03`, `part 3`, `disc 1`, `cd2`, or a bare number at the position a track number is
  # conventionally written) — mirrors `BookSources.stem/1`'s own normalization plus the token
  # strip. All candidates must reduce to the SAME stem; see `check_mixed_filenames/1`.
  @track_token ~r/\b(?:track|part|disc|cd)?\s*0?\d{1,3}\b/iu

  defp filename_stem(path) do
    path
    |> Path.basename()
    |> Path.rootname()
    |> String.downcase()
    |> String.replace(@track_token, " ")
    |> String.replace(~r/[ ._-]+/u, " ")
    |> String.trim()
  end

  defp check_mixed_filenames(tracks) when length(tracks) <= 1, do: :ok

  defp check_mixed_filenames(tracks) do
    if tracks |> Enum.map(& &1.stem) |> Enum.uniq() |> length() > 1,
      do: {:error, :mixed_book_filenames},
      else: :ok
  end

  # Only when `AudioProbe` is configured — an unanswered/absent probe is "can't verify the
  # stronger signal", never a positive "these differ" verdict.
  defp check_mixed_tags(tracks) when length(tracks) <= 1, do: :ok

  defp check_mixed_tags(tracks) do
    if is_nil(audio_probe()) or
         (not tag_disagreement?(tracks, :album_tag) and not tag_disagreement?(tracks, :title_tag)),
       do: :ok,
       else: {:error, :mixed_book_tags}
  end

  defp tag_disagreement?(tracks, key) do
    tracks
    |> Enum.map(&(&1.probe && Map.get(&1.probe, key)))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> length() > 1
  end

  defp order_tracks([single]), do: {:ok, [single]}

  defp order_tracks(tracks) do
    if Enum.any?(tracks, &contradictory?/1) do
      {:error, :track_order_contradictory}
    else
      order_by_evidence(tracks)
    end
  end

  defp contradictory?(%{probe: %{track_tag: tag}, filename_track: filename})
       when not is_nil(tag) and not is_nil(filename) and tag != filename,
       do: true

  defp contradictory?(_track), do: false

  defp order_by_evidence(tracks) do
    cond do
      Enum.all?(tracks, &(&1.probe && &1.probe.track_tag)) ->
        {:ok, Enum.sort_by(tracks, &{&1.probe.disc_tag || 1, &1.probe.track_tag})}

      Enum.all?(tracks, & &1.filename_track) ->
        {:ok, Enum.sort_by(tracks, &{&1.filename_disc || 1, &1.filename_track})}

      true ->
        {:error, :track_order_unknown}
    end
  end

  defp check_container(ordered) do
    formats = ordered |> Enum.map(& &1.format) |> Enum.uniq()

    if formats == [hd(formats)] and length(formats) == 1,
      do: :ok,
      else: {:error, :container_mismatch}
  end

  defp finalize(ordered) do
    Enum.map(ordered, fn track ->
      %{
        path: track.path,
        format: track.format,
        track_number: track.probe && track.probe.track_tag,
        disc_number: track.probe && track.probe.disc_tag,
        duration_seconds: track.probe && track.probe.duration_seconds,
        chapter_count: track.probe && track.probe.chapter_count,
        order_disc: resolved_disc(track)
      }
    end)
  end

  defp resolved_disc(%{probe: %{disc_tag: disc}}) when not is_nil(disc), do: disc
  defp resolved_disc(%{filename_disc: disc}) when not is_nil(disc), do: disc
  defp resolved_disc(_track), do: 1

  # --- filename track/disc number extraction — captures rather than discards, unlike
  # `filename_stem/1`'s strip. Priority: a leading number, then a keyword-prefixed number
  # anywhere, then a trailing number after a separator — covers the plan's own examples
  # ("track 03", "03 - Title.mp3", "CD2/07.mp3").

  @leading_number ~r/^\s*0*(\d{1,3})\b/u
  @keyword_number ~r/\b(?:track|chapter|part|no\.?|nr\.?)\s*0*(\d{1,3})\b/iu
  @trailing_number ~r/[-_]\s*0*(\d{1,3})\s*$/u
  @disc_marker ~r/\b(?:cd|disc)\s*0*(\d{1,3})\b/iu

  defp filename_track_number(path) do
    base = path |> Path.basename() |> Path.rootname()

    Enum.find_value([@leading_number, @keyword_number, @trailing_number], fn regex ->
      case Regex.run(regex, base) do
        [_match, number] -> String.to_integer(number)
        nil -> nil
      end
    end)
  end

  # Disc evidence lives in a PARENT directory segment (`CD2/07.mp3`), never in the basename
  # itself — a basename's own leading/trailing number is the track, not the disc.
  defp filename_disc_number(path) do
    path
    |> Path.dirname()
    |> Path.split()
    |> Enum.find_value(fn segment ->
      case Regex.run(@disc_marker, segment) do
        [_match, number] -> String.to_integer(number)
        nil -> nil
      end
    end)
  end

  defp fs, do: Application.fetch_env!(:cinder, :filesystem)
end
