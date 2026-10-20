defmodule Cinder.Library.ImportedQuality do
  @moduledoc """
  The imported quality: what Cinder recorded about the file a movie or episode holds, and the one
  list of the `imported_*` columns that store it. Field `f` is column `imported_f`.

  `column_names/2` is what the schemas cast and what a writer may set, so a new column is one field
  here plus the migration and the schema `field`.
  """

  require Logger

  alias Cinder.Acquisition.Parser
  alias Cinder.Catalog.{Episode, Movie}
  alias Cinder.Library.Sidecars

  # The fields `Cinder.Library.Upgrade` ranks on: read from the file's name, and its size.
  @ranked [:resolution, :size, :language, :source]
  # The fields found in the file by the media-info probe, and next to it by the sidecar scan.
  @media [:audio_languages, :default_audio_language, :embedded_subtitles, :sidecar_subtitles]
  # Episode rows carry no default-audio column.
  @absent %{Movie => [], Episode => [:default_audio_language]}
  @columns Map.new(@ranked ++ @media, &{&1, :"imported_#{&1}"})

  defstruct @ranked ++ @media

  @type t :: %__MODULE__{
          resolution: String.t() | nil,
          size: non_neg_integer() | nil,
          language: String.t() | nil,
          source: String.t() | nil,
          audio_languages: [String.t()] | nil,
          default_audio_language: String.t() | nil,
          embedded_subtitles: [String.t()] | nil,
          sidecar_subtitles: [String.t()] | nil
        }

  @type schema :: Movie | Episode
  @type row :: %Movie{} | %Episode{}

  @doc """
  The `imported_*` columns `schema` has: all of them, or only the `:media` ones (the probed and
  scanned languages, which `Cinder.Catalog.set_media_info/2` writes).
  """
  @spec column_names(schema(), :all | :media) :: [atom()]
  def column_names(schema, group \\ :all) when is_map_key(@absent, schema),
    do: Enum.map(fields(schema, group), &Map.fetch!(@columns, &1))

  @doc """
  The quality of a download's `files` (`[{path, size}]`, a movie's parts in order) as an import
  would record it, sidecars not yet scanned (`for_outcome/4` does that).

  Resolution, source and language come from `path`'s name, each filled from `release_title:`
  where the name says nothing; size is the files' sum. Each file is probed for its audio and
  embedded-subtitle languages (its `reports:` entry when the policy check already probed it), and
  the lists are merged across parts, the first established default audio language winning.
  `probe: false` skips the probe. Never fails: a disabled or failed probe records no languages.
  """
  @spec capture(Path.t(), [{Path.t(), non_neg_integer()}], keyword()) :: t()
  def capture(path, files, opts \\ []) do
    named = named(Parser.parse(Path.basename(path)), Keyword.get(opts, :release_title))

    media =
      if Keyword.get(opts, :probe, true),
        do: probe_all(Enum.map(files, &elem(&1, 0)), Keyword.get(opts, :reports, %{})),
        else: empty_media()

    struct!(
      __MODULE__,
      named
      |> Map.merge(media)
      |> Map.merge(%{size: files |> Enum.map(&elem(&1, 1)) |> Enum.sum(), sidecar_subtitles: []})
    )
  end

  # The recorded quality is what every later upgrade comparison ranks the record on, so it must be
  # at least as informed as the RELEASE TITLE the sweep decided from — otherwise a terse inner file
  # name (`S03E01.mkv` inside `Show.S03.1080p.BluRay-GRP`) records nils, nils rank last, and the
  # release keeps out-ranking the very file it produced, re-downloading forever (#275). Release and
  # record are parsed by the same `Parser`, so after the backfill a release provably cannot beat
  # its own output on resolution, source or language.
  #
  # Field by field, never wholesale: the file's own name always wins where it says something, so a
  # `720p` file inside a `1080p` pack still records 720p and stays a legitimate upgrade target.
  # `size` is never backfilled — the release's size is the whole container (extras, subs, samples),
  # the file's is the file.
  defp named(parsed, release_title) do
    # Parser.parse/1 is total: a nil title yields an all-nil parse, i.e. no backfill.
    release = Parser.parse(release_title)

    %{
      resolution: parsed.resolution || release.resolution,
      source: parsed.source || release.source,
      language: parsed.language || release.language
    }
  end

  defp probe_all(paths, reports) do
    Enum.reduce(paths, empty_media(), fn path, media ->
      found = cached_or_probe(path, reports)

      %{
        audio_languages: Enum.uniq(media.audio_languages ++ found.audio_languages),
        embedded_subtitles: Enum.uniq(media.embedded_subtitles ++ found.embedded_subtitles),
        default_audio_language: media.default_audio_language || found.default_audio_language
      }
    end)
  end

  defp cached_or_probe(path, reports) do
    case Map.fetch(reports, path) do
      {:ok, report} -> probed(report)
      :error -> probe(path)
    end
  end

  # Empty lists when media_info is disabled or the probe errors — never blocks the import.
  defp probe(path) do
    case Application.get_env(:cinder, :media_info) do
      nil -> empty_media()
      impl -> probe(impl, path)
    end
  end

  defp probe(impl, path) do
    case impl.probe(path) do
      {:ok, %{audio: _, subtitles: _} = report} ->
        probed(report)

      other ->
        # Degrading to empty metadata is deliberate — but a broken/missing ffprobe must be
        # diagnosable: silently-empty fields read as "the file has no tags", not "the probe
        # is broken" (media_info is on by default, and there is no health row for it).
        Logger.warning("media-info probe failed for #{path}: #{inspect(other)}")
        empty_media()
    end
  end

  # Map.get: `default_audio` is an optional key on the behaviour, so a Mox stub returning only
  # audio/subtitles stays valid (issue #197).
  defp probed(%{audio: audio, subtitles: subtitles} = report),
    do: %{
      audio_languages: audio,
      embedded_subtitles: subtitles,
      default_audio_language: Map.get(report, :default_audio)
    }

  defp empty_media,
    do: %{audio_languages: [], embedded_subtitles: [], default_audio_language: nil}

  @doc """
  The quality to record on `record` for a file `Cinder.Library.StagedImport.place/5` staged at
  `dest:` with `outcome`, when `incoming` is the download's `capture/3`.

  The incoming quality belongs only to bytes that landed (`:placed`, `:replaced`), with the
  sidecar languages of `sidecars_from:` (the download file, when it came in a folder), or to a
  forced re-import of the very same file (`forced?: true`, a manual re-import after a crash).
  Otherwise the row keeps what it recorded, or, when its quality is unrecorded, adopts the file it
  found, with the sidecars already at `dest` (issue #128). A `:kept` file logs that the download
  was not an upgrade.
  """
  @spec for_outcome(t(), :placed | :replaced | :same_file | :kept, row(), keyword()) :: t()
  def for_outcome(%__MODULE__{} = incoming, outcome, _record, opts)
      when outcome in [:placed, :replaced] do
    case Keyword.get(opts, :sidecars_from) do
      nil -> incoming
      source -> %{incoming | sidecar_subtitles: sidecar_languages(source)}
    end
  end

  def for_outcome(%__MODULE__{} = incoming, :same_file, record, opts) do
    if Keyword.get(opts, :forced?, false),
      do: incoming,
      else: existing(record, incoming, Keyword.fetch!(opts, :dest))
  end

  def for_outcome(%__MODULE__{} = incoming, :kept, record, opts) do
    dest = Keyword.fetch!(opts, :dest)
    kept = existing(record, incoming, dest)

    Logger.warning(
      "kept existing #{inspect(kept.resolution)} file at #{dest}; new release not an upgrade"
    )

    kept
  end

  defp existing(record, incoming, dest) do
    recorded = of(record)

    if unrecorded?(recorded),
      do: %{incoming | sidecar_subtitles: sidecar_languages(dest)},
      else: recorded
  end

  defp sidecar_languages(video),
    do: video |> Sidecars.files() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

  @doc """
  `record`'s imported quality with its languages read again from its library files: each file
  probed and its sidecars scanned, merged the way `capture/3` merges a movie's parts. The ranked
  fields stay as recorded. For the media-info backfill.
  """
  @spec recapture(row()) :: t()
  def recapture(%schema{} = record) when is_map_key(@absent, schema) do
    paths = schema.file_paths(record)
    sidecars = paths |> Enum.flat_map(&sidecar_languages/1) |> Enum.uniq()
    struct!(of(record), Map.put(probe_all(paths, %{}), :sidecar_subtitles, sidecars))
  end

  @doc """
  Whether `quality` is unrecorded: no resolution, size or language. On a held file that means it
  was adopted, or imported before the quality columns existed. Takes any map with those keys.
  """
  @spec unrecorded?(map()) :: boolean()
  def unrecorded?(%{resolution: nil, size: nil, language: nil}), do: true
  def unrecorded?(%{}), do: false

  @doc """
  Reads a movie's or an episode's imported quality off its row, raw: a stored nil stays nil (a
  row never probed has nil lists, not `[]`), so `columns/2` writes it back unchanged.
  """
  @spec of(row()) :: t()
  def of(%schema{} = record) when is_map_key(@absent, schema) do
    struct!(
      __MODULE__,
      Enum.map(fields(schema, :all), &{&1, Map.fetch!(record, Map.fetch!(@columns, &1))})
    )
  end

  @doc """
  The `imported_*` attrs that record `quality` on a `schema` row, one per column it has; `nil`
  clears them all. Only an `%ImportedQuality{}` is accepted, so an old bare map fails here instead
  of writing nil.
  """
  @spec columns(t() | nil, schema()) :: %{atom() => term()}
  def columns(nil, schema), do: Map.new(column_names(schema), &{&1, nil})

  def columns(%__MODULE__{} = quality, schema) when is_map_key(@absent, schema),
    do: Map.new(fields(schema, :all), &{Map.fetch!(@columns, &1), Map.fetch!(quality, &1)})

  defp fields(schema, :all), do: (@ranked ++ @media) -- Map.fetch!(@absent, schema)
  defp fields(schema, :media), do: @media -- Map.fetch!(@absent, schema)
end
