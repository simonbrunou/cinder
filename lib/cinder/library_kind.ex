defmodule Cinder.LibraryKind do
  @moduledoc """
  The media kinds Cinder manages, and what each one is capable of.

  `Cinder.Library.kinds/0` is the *video* subset of this registry. That split is the point:
  every per-kind video derivation (Plex sections, size bands, release policy, media-server
  reconciliation, disk telemetry, the setup gate) hangs off the narrower list, so a book kind
  inherits nothing it has not explicitly opted into.

  The registry key is the books contract's media-kind axis: B2 edition/file `media_kind` values
  use these same atoms, so there is one media-kind axis rather than a parallel library-kind
  vocabulary. `root_role/1` is the contract's separate filesystem-role axis. The two axes
  coincide for video, but diverge for ebooks: media kind `:ebook` uses root role `:books`.

  Ordered keyword list, not a map: the order is the UI order, and `all/0` derives from it so a
  new kind cannot be added to the registry and forgotten in the list. Pure literal — read at
  boot and at config-eval time, so it must not touch Application env or the Repo.
  """

  @kinds [
    movies: %{video?: true, handlings: [:standard, :anime], label: "Movies", root_role: :movies},
    tv: %{video?: true, handlings: [:standard, :anime], label: "TV", root_role: :tv},
    ebook: %{video?: false, handlings: [:standard], label: "Ebooks", root_role: :books},
    audiobook: %{
      video?: false,
      handlings: [:standard],
      label: "Audiobooks",
      root_role: :audiobooks
    }
  ]

  @doc "Every media kind Cinder manages, in display order."
  @spec all() :: [atom()]
  def all, do: Keyword.keys(@kinds)

  @doc "The media kinds whose assets are video files."
  @spec video() :: [atom()]
  def video, do: Enum.filter(all(), &video?/1)

  @doc "The non-video media kinds managed through the books catalog."
  @spec books() :: [atom()]
  def books, do: Enum.reject(all(), &video?/1)

  @doc "Whether `kind`'s assets are video files."
  @spec video?(atom()) :: boolean()
  def video?(kind), do: fetch!(kind).video?

  @doc "The handling modes `kind` supports (book media is `:standard` only)."
  @spec handlings(atom()) :: [atom()]
  def handlings(kind), do: fetch!(kind).handlings

  @doc "Whether `kind` supports `handling`."
  @spec handling?(atom(), atom()) :: boolean()
  def handling?(kind, handling), do: handling in handlings(kind)

  @doc "The display label for `kind`."
  @spec label(atom()) :: String.t()
  def label(kind), do: fetch!(kind).label

  @doc """
  The singular, human-facing name for one book asset — what a request row or a notification
  calls a single copy, as opposed to `label/1`'s plural collection name ("Ebooks").

  The casing is each word's ordinary English spelling and must match the `"%{title} (eBook)"` /
  `"%{title} (audiobook)"` gettext msgids the UI and email render, so one work's format reads
  the same on every surface.

  Book kinds only: a video kind has no singular format word, and no caller wants one. Defined
  here rather than in each notifier so the user-visible spelling is not derived from the enum
  atom's own name. Adding a book kind without a clause raises, and
  `Cinder.Requests.BookRequestTest` fences that across every kind in `books/0`.
  """
  @spec format_label(atom()) :: String.t()
  def format_label(:ebook), do: "eBook"
  def format_label(:audiobook), do: "audiobook"

  @doc "The filesystem-root role for `kind`."
  @spec root_role(atom()) :: atom()
  def root_role(kind), do: fetch!(kind).root_role

  defp fetch!(kind), do: Keyword.fetch!(@kinds, kind)
end
