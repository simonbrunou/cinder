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

  @doc """
  The adapter for a request's target kind. A target type with no adapter (`"series"`, `"episode"`)
  cannot be approved: it names no row Cinder knows how to create. `Cinder.Requests` refuses to
  file one too, and `Cinder.Requests.approvable_target?/1` asks the same question for a view.
  """
  # Reads only the target type: `Cinder.Requests` asks before a book request's `target_id` exists.
  @spec adapter(%{optional(atom()) => term()}) :: {:ok, module()} | {:error, :unsupported_target}
  def adapter(%{target_type: "movie"}), do: {:ok, __MODULE__.Movie}
  def adapter(%{target_type: "season"}), do: {:ok, __MODULE__.Season}
  def adapter(%{target_type: "book"}), do: {:ok, __MODULE__.Book}
  def adapter(_target), do: {:error, :unsupported_target}

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
