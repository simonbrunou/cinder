defmodule Cinder.MediaKind do
  @moduledoc """
  The media kinds Cinder manages, and what each one is capable of.

  `Cinder.Library.kinds/0` is the *video* subset of this registry. That split is the point:
  every per-kind video derivation (Plex sections, size bands, release policy, media-server
  reconciliation, disk telemetry, the setup gate) hangs off the narrower list, so a book kind
  inherits nothing it has not explicitly opted into.

  Ordered keyword list, not a map: the order is the UI order, and `all/0` derives from it so a
  new kind cannot be added to the registry and forgotten in the list. Pure literal — read at
  boot and at config-eval time, so it must not touch Application env or the Repo.
  """

  @kinds [
    movies: %{video?: true, handlings: [:standard, :anime], label: "Movies"},
    tv: %{video?: true, handlings: [:standard, :anime], label: "TV"},
    ebooks: %{video?: false, handlings: [:standard], label: "Ebooks"},
    audiobooks: %{video?: false, handlings: [:standard], label: "Audiobooks"}
  ]

  @doc "Every media kind Cinder manages, in display order."
  @spec all() :: [atom()]
  def all, do: Keyword.keys(@kinds)

  @doc "The media kinds whose assets are video files."
  @spec video() :: [atom()]
  def video, do: Enum.filter(all(), &video?/1)

  @doc "Whether `kind`'s assets are video files."
  @spec video?(atom()) :: boolean()
  def video?(kind), do: fetch!(kind).video?

  @doc "The handling modes `kind` supports (books are `:standard` only)."
  @spec handlings(atom()) :: [atom()]
  def handlings(kind), do: fetch!(kind).handlings

  @doc "Whether `kind` supports `handling`."
  @spec handling?(atom(), atom()) :: boolean()
  def handling?(kind, handling), do: handling in handlings(kind)

  @doc "The display label for `kind`."
  @spec label(atom()) :: String.t()
  def label(kind), do: fetch!(kind).label

  defp fetch!(kind), do: Keyword.fetch!(@kinds, kind)
end
