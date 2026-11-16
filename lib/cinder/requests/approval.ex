defmodule Cinder.Requests.Approval do
  @moduledoc """
  The kind seam of request approval.

  `Cinder.Requests` owns the one approval transaction for both an admin approval of a pending
  request and an auto-approval at request time: it writes the approved request, re-checks an
  auto-approval's quota, and announces the approval after commit. An adapter per request target
  kind owns the
  three steps that differ by kind, in this order:

  1. `c:prepare/2`, before the transaction: provider I/O and reads, no writes.
  2. `c:create/2`, inside the transaction after the request write: creates or arms the target.
  3. `c:publish/2`, after commit: announces the target's own change, and decides an existing
     title's anime hold again when the approval changed its profile or Audio pick.

  Only `Cinder.Requests` calls an adapter. `c:create/2` writes a `:requested` movie or series row,
  or arms a book target, with no approval check of its own: the approval gate is its caller.
  """

  alias Cinder.Catalog
  alias Cinder.Catalog.Profile
  alias Cinder.LibraryKind
  alias Cinder.Requests.{Request, Target}

  @typedoc "What `c:prepare/2` read, handed to `c:create/2` unchanged."
  @type prepared :: term()

  @typedoc "What `c:create/2` wrote, handed to `c:publish/2` unchanged."
  @type created :: term()

  @doc """
  Reads everything the target needs before the transaction opens, so no provider round-trip holds
  SQLite's write lock. Writes nothing.
  """
  @callback prepare(Target.ref(), Profile.t() | nil) :: {:ok, prepared()} | {:error, term()}

  @doc """
  Creates or arms the target inside the approval transaction, after the request write, with the
  profile as re-read inside it. An `{:error, reason}` rolls the whole approval back. Never
  broadcasts.
  """
  @callback create(prepared(), Profile.t() | nil) :: {:ok, created()} | {:error, term()}

  @doc """
  Announces the target's own change after commit, and decides an existing title's anime hold again
  (`Cinder.Catalog.reresolve_anime_hold/1`). Never announces the approval itself.
  """
  @callback publish(created(), approved :: Request.t()) :: :ok

  # The one list of target types an approval can create, each with its adapter. Adding a type
  # here (plus its adapter module) is the only edit `adapter/1`, `approvable_types/0` and the
  # API's payload check need. Not `Request`'s `@target_types`, which keeps `"series"` and
  # `"episode"` so legacy rows still load and validate.
  @adapters %{
    "movie" => __MODULE__.Movie,
    "season" => __MODULE__.Season,
    "book" => __MODULE__.Book
  }

  @doc """
  The adapter for a request's target kind. A target type with no adapter (`"series"`, `"episode"`)
  cannot be approved: it names no row Cinder knows how to create. `Cinder.Requests` refuses to
  file one too, and `Cinder.Requests.approvable_target?/1` asks the same question for a view.
  """
  # Reads only the target type: `Cinder.Requests` asks before a book request's `target_id` exists.
  @spec adapter(%{optional(atom()) => term()}) :: {:ok, module()} | {:error, :unsupported_target}
  def adapter(%{target_type: type}) when is_map_key(@adapters, type),
    do: {:ok, Map.fetch!(@adapters, type)}

  def adapter(_target), do: {:error, :unsupported_target}

  @doc """
  The target types an approval can create, sorted: the types `adapter/1` answers `{:ok, _}` for.
  The API accepts exactly these on create.
  """
  @spec approvable_types() :: [String.t()]
  def approvable_types, do: @adapters |> Map.keys() |> Enum.sort()

  @doc """
  The profile kind a request target uses, for any `Cinder.Requests.Request` target type, legacy
  ones included: `:movies` for a movie; `:tv` for a season, series or episode; a book's own
  `media_kind` when it is a book kind; `nil` for anything else.

  Takes the request or attrs map, not the target type alone: `"book"` names no profile kind by
  itself, the (work, media_kind) axis does. A book's `media_kind` is validated, not merely
  fetched: the answer feeds `Cinder.Catalog.list_profiles/1`, whose head guards on the kind atoms,
  so a string from a form or a hand-built attrs map would raise there instead of yielding the
  `{:error, :invalid_media_profile}` every other bad-profile input gets.
  """
  @spec profile_kind(%{optional(atom()) => term()}) :: atom() | nil
  def profile_kind(%{target_type: "movie"}), do: :movies
  def profile_kind(%{target_type: type}) when type in ["series", "season", "episode"], do: :tv

  def profile_kind(%{target_type: "book"} = target) do
    kind = Map.get(target, :media_kind)
    if kind in LibraryKind.books(), do: kind
  end

  def profile_kind(_target), do: nil

  @doc false
  # The movie and season adapters' handling for provider preparation and creation. No profile
  # means the requester proposed none: Auto, which resolves like Standard.
  def handling(nil), do: :auto
  def handling(%Profile{handling: handling}), do: handling

  @doc false
  # Points a movie or series at the approval's profile without publishing, inside the approval
  # transaction. Returns whether anything changed, so an existing movie's post-commit publish
  # knows whether open views need a `{:movie_updated, _}`.
  def assign_selected_profile(title, nil), do: {:ok, {title, false}}

  def assign_selected_profile(%{profile_id: id, media_profile: handling} = title, %Profile{
        id: id,
        handling: handling
      }),
      do: {:ok, {title, false}}

  def assign_selected_profile(title, profile) do
    case Catalog.assign_profile(title, profile, publish: false) do
      {:ok, title} -> {:ok, {title, true}}
      {:error, reason} -> {:error, reason}
    end
  end
end
