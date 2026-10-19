defmodule Cinder.Acquisition.BookKind do
  @moduledoc """
  The rules that differ between the two book kinds, e-book and audiobook, as plain data.

  `Cinder.Acquisition.BookScorer` and `Cinder.Acquisition.BookParser` serve both kinds with one
  check chain and one tag-region parser. Everything that differs between an e-book release and an
  audiobook release is a value here, not a branch there:

    * `known_formats` — every container token the parser recognizes, in recognizer order
      (most-specific first, so `azw3` is not swallowed by `azw`). Formats the kind refuses are
      recognized *on purpose*: the scorer has to tell "a PDF scan, refused" from "no format
      stated at all", and it can only do that if the parser names what it refuses. The audiobook
      kind recognizes EPUB/AZW3/MOBI for the same reason, so a miscategorized e-book reads as
      "wrong family" rather than "unknown".
    * `accepted_formats` — the formats the kind accepts, most preferred first.
    * `size_band` — the inclusive `{min, max}` in bytes. Module data rather than settings:
      `movies_min_size` has no meaning for a book and the settings registry generates size bands
      for video kinds only (`Cinder.LibraryKind.video?/1`).
    * `edition_words` — leftover release words, beyond the family-wide edition vocabulary and the
      kind's own format tokens, that the title check treats as metadata rather than as a word
      naming a different work.
    * `tag_words` — words, beyond the family-wide ones, that the parser accepts inside a tag
      region.
    * `narrated?` — whether releases of this kind carry a narrator credit. It drives three things
      at once: the parser's `narrator` field, the scorer dropping a "(Narrated by …)" bracket
      group, and the `narrator` key in accept evidence.

  ## E-book

  The parity contract's e-book formats: EPUB, AZW3 and MOBI, EPUB preferred, no conversion. The
  band is 64 KB – 200 MB: the floor rejects the placeholder/stub torrent, the ceiling the
  multi-gigabyte "complete works" pack, which is a different release from the one requested even
  when it is genuine.

  ## Audiobook

  M4B and MP3, M4B preferred, and a 5 MB – 8 GB band matched to real MP3/AAC bitrates across a
  1–40+ hour recording. Both are B7a's own judgment (§0.1 of the audiobook plan), not
  contract-derived: the contract names M4B as preferred and gestures at "common multipart audio
  containers" without enumerating a size or format set.
  """

  @enforce_keys [
    :media_kind,
    :known_formats,
    :accepted_formats,
    :size_band,
    :edition_words,
    :tag_words,
    :narrated?
  ]
  defstruct @enforce_keys

  @type media_kind :: :ebook | :audiobook

  @type t :: %__MODULE__{
          media_kind: media_kind(),
          known_formats: [atom(), ...],
          accepted_formats: [atom(), ...],
          size_band: {pos_integer(), pos_integer()},
          edition_words: [String.t()],
          tag_words: [String.t()],
          narrated?: boolean()
        }

  # Plain maps: a struct cannot be built in the body of the module that defines it.
  @kinds %{
    ebook: %{
      media_kind: :ebook,
      known_formats: [:epub, :azw3, :azw, :mobi, :pdf, :djvu, :fb2, :lit, :cbz, :cbr, :rtf],
      accepted_formats: [:epub, :azw3, :mobi],
      size_band: {64 * 1024, 200 * 1024 * 1024},
      edition_words: ~w(ebook),
      tag_words: ~w(ebook scan ocr),
      narrated?: false
    },
    audiobook: %{
      media_kind: :audiobook,
      known_formats: [:m4b, :mp3, :m4a, :aac, :flac, :ogg, :wma, :epub, :azw3, :mobi],
      accepted_formats: [:m4b, :mp3],
      size_band: {5 * 1024 * 1024, 8 * 1024 * 1024 * 1024},
      # `narrated`/`read` cover the rare bare (unbracketed) narrator credit; the bracketed form is
      # dropped whole by the scorer before this list is consulted.
      edition_words: ~w(audiobook narrated read rip),
      tag_words: ~w(audiobook rip narrated read by),
      narrated?: true
    }
  }

  @doc "Every book kind with rules."
  @spec all() :: [media_kind()]
  def all, do: Map.keys(@kinds)

  @doc "The rules for `media_kind`. Raises `ArgumentError` for a kind that is not a book kind."
  @spec fetch!(media_kind()) :: t()
  def fetch!(media_kind) do
    case Map.fetch(@kinds, media_kind) do
      {:ok, rules} -> struct!(__MODULE__, rules)
      :error -> raise ArgumentError, "not a book kind: #{inspect(media_kind)}"
    end
  end

  @doc "The formats `media_kind` accepts, most preferred first."
  @spec accepted_formats(media_kind()) :: [atom(), ...]
  def accepted_formats(media_kind), do: fetch!(media_kind).accepted_formats

  @doc "The inclusive size band for `media_kind`, in bytes, as `{min, max}`."
  @spec size_band(media_kind()) :: {pos_integer(), pos_integer()}
  def size_band(media_kind), do: fetch!(media_kind).size_band
end
