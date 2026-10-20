defmodule Cinder.Catalog.Attention do
  @moduledoc """
  Operator attention: the one classification of a movie, TV grab or series that every pipeline
  surface reads. `classify/1` answers, per item:

    * `phase`: `:active` (Cinder is working on it), `:attention` (it needs attention: `/activity`
      offers an action or names a fix that resolves it), `:waiting` (it waits on a change the
      operator does not make; no item waits today) or `:idle` (nothing in progress);
    * `reason`: why it needs attention or waits (`nil` otherwise);
    * `badge`: the `<.status_badge>` status it wears (`nil` for a book target);
    * `actions`: its offered actions, one atom per operator function, in render order;
    * `fix`: where the operator makes the change that clears it, when that change is on another
      page (`nil` otherwise): `:detail_page` (the title's Audio pick and profile) or
      `:subtitle_settings` (the subtitle languages in Settings).

  A series classifies only on its search-time anime hold: its downloads classify as grabs.

  Buttons render from `actions`, and each operator function refuses an item that does not offer
  its action (`offers?/2`), so a view and the write it triggers can never disagree. A view picks
  its copy from `{action, reason}`: `:retry` with reason `:verification_hold` reads "Retry
  verification".

  | Action | Operator function |
  |---|---|
  | movie `:retry` | `MovieLifecycle.retry/1` |
  | movie `:cancel` | `MovieLifecycle.cancel/2` |
  | movie `:cancel_upgrade` | `MovieLifecycle.abort_upgrade/2` |
  | movie `:manual_search` | `Grabs.manual_grab_movie/2` |
  | grab `:retry_mapping` | `ReleaseVerification.retry_grab_mapping/1` |
  | grab `:retry_verification` | `ReleaseVerification.retry_grab_verification/1` |
  | grab `:import_anyway` | `ReleaseVerification.import_grab_anyway/2` |
  | grab `:discard` | `Grabs.cancel_mapping_grab/1` |
  | grab `:cancel` | `Grabs.cancel_grab/1` |

  A residual-files grab's per-file decisions stay with `Cinder.Download.TvPoller`. Book targets
  classify through `Cinder.Books.Attention` into the same struct.
  """

  import Ecto.Query

  alias Cinder.Catalog.{Grab, GrabFile, Grabs, Movie, MovieLifecycle, Series}
  alias Cinder.Repo

  @enforce_keys [:phase]
  defstruct [:phase, :reason, :badge, :fix, actions: []]

  @type phase :: :active | :attention | :waiting | :idle

  @type fix :: :detail_page | :subtitle_settings

  @typedoc "An offered action: one atom per operator function (see the tables above and in `Cinder.Books.Attention`)."
  @type action ::
          :retry
          | :cancel
          | :cancel_upgrade
          | :manual_search
          | :retry_mapping
          | :retry_verification
          | :import_anyway
          | :discard
          | :clear_blocklist
          | :replace
          | :pause
          | :resume

  @type t :: %__MODULE__{
          phase: phase(),
          reason: atom() | nil,
          badge: atom() | nil,
          actions: [action()],
          fix: fix() | nil
        }

  @doc "Classifies a movie, a TV grab or a series. Pure: reads only the struct's loaded fields."
  @spec classify(Movie.t() | Grab.t() | Series.t()) :: t()
  def classify(%Movie{status: status} = movie) do
    cond do
      anime_held?(movie) ->
        anime_hold(movie.anime_hold_reason, [:cancel])

      verification_hold?(movie) ->
        attention(:verification_hold, :verification_hold, [:retry, hold_release(movie)])

      status in MovieLifecycle.parked_statuses() ->
        attention(status, status, [:retry, :manual_search])

      status == :upgrading ->
        active(status, [:cancel_upgrade])

      status in MovieLifecycle.pipeline_statuses() ->
        active(status, [:cancel])

      status == :available ->
        %__MODULE__{phase: :idle, badge: status, actions: [:manual_search]}

      status == :cancelled ->
        %__MODULE__{phase: :idle, badge: status}
    end
  end

  def classify(%Grab{mapping_status: :needs_mapping}),
    do: attention(:needs_mapping, :needs_mapping, [:retry_mapping, :discard])

  def classify(%Grab{mapping_status: :verification_blocked}),
    do:
      attention(:verification_blocked, :verification_blocked, [
        :retry_verification,
        :import_anyway,
        :cancel
      ])

  # A residual-files hold wears the `:needs_mapping` badge.
  def classify(%Grab{} = grab) do
    cond do
      Grabs.unresolved_grab_files(grab) != [] ->
        attention(:residual_files, :needs_mapping, [:cancel])

      is_nil(grab.content_path) ->
        active(:downloading, [:cancel])

      true ->
        active(:downloaded, [:cancel])
    end
  end

  # Cancelling a series, or setting its monitoring to none, lifts its hold: no sweep would.
  def classify(%Series{anime_hold_reason: nil}), do: %__MODULE__{phase: :idle}
  def classify(%Series{anime_hold_reason: reason}), do: anime_hold(reason, [])

  @doc "True when `item` offers `action` in its current state."
  @spec offers?(Movie.t() | Grab.t() | Series.t(), action()) :: boolean()
  def offers?(item, action), do: action in classify(item).actions

  @doc """
  Movies, grabs and series per phase, every phase present. SQL groups the rows by the fields
  `classify/1` reads (a movie's status, hold origin and anime hold reason; a grab's mapping
  status and whether it has an undecided file; a series' anime hold reason), then one
  representative per group is classified here, so the counts never re-encode the rule. Read by
  the dashboard and, through `attention_count/0`, the Activity nav badge.
  """
  @spec counts() :: %{
          movie: %{phase() => non_neg_integer()},
          grab: %{phase() => non_neg_integer()},
          series: %{phase() => non_neg_integer()}
        }
  def counts do
    movies =
      from(m in Movie,
        group_by: [m.status, m.verification_hold_origin, m.anime_hold_reason],
        select: {m.status, m.verification_hold_origin, m.anime_hold_reason, count(m.id)}
      )
      |> Repo.all()
      |> Enum.map(fn {status, origin, reason, n} ->
        {%Movie{status: status, verification_hold_origin: origin, anime_hold_reason: reason}, n}
      end)

    undecided =
      from(f in GrabFile,
        where: is_nil(f.decision),
        distinct: true,
        select: %{grab_id: f.grab_id}
      )

    grabs =
      from(g in Grab,
        left_join: u in subquery(undecided),
        on: u.grab_id == g.id,
        group_by: [g.mapping_status, fragment("? IS NOT NULL", u.grab_id)],
        select: {g.mapping_status, fragment("? IS NOT NULL", u.grab_id), count(g.id)}
      )
      |> Repo.all()
      |> Enum.map(fn {mapping_status, residual, n} ->
        files = if sql_true?(residual), do: [%GrabFile{decision: nil}], else: []
        {%Grab{mapping_status: mapping_status, grab_files: files}, n}
      end)

    series =
      from(s in Series,
        group_by: s.anime_hold_reason,
        select: {s.anime_hold_reason, count(s.id)}
      )
      |> Repo.all()
      |> Enum.map(fn {reason, n} -> {%Series{anime_hold_reason: reason}, n} end)

    %{movie: tally(movies), grab: tally(grabs), series: tally(series)}
  end

  @doc "How many movies, grabs and series need attention: the Activity nav badge (`0` hides it)."
  @spec attention_count() :: non_neg_integer()
  def attention_count do
    %{movie: %{attention: movies}, grab: %{attention: grabs}, series: %{attention: series}} =
      counts()

    movies + grabs + series
  end

  # SQLite returns a boolean expression as 0/1.
  defp sql_true?(value), do: value in [true, 1]

  defp tally(groups) do
    Enum.reduce(groups, %{active: 0, attention: 0, waiting: 0, idle: 0}, fn {item, n}, acc ->
      Map.update!(acc, classify(item).phase, &(&1 + n))
    end)
  end

  defp anime_held?(%Movie{status: status, anime_hold_reason: reason}),
    do: status in [:requested, :searching] and is_binary(reason)

  defp anime_hold(reason, actions) do
    {phase, fix} = anime_hold_fix(reason)
    %__MODULE__{phase: phase, reason: :anime_hold, badge: :anime_hold, actions: actions, fix: fix}
  end

  # Each anime hold reason (an `AnimePreferences.resolve/2` error) and the fix that clears it. The
  # sweep lifts a hold once preferences resolve, but both reasons resolve only after the operator
  # changes something, so they need attention. A reason that cleared without the operator would
  # map to `{:waiting, nil}` here. A reason this Cinder does not know still counts: after the
  # profile on the detail page switches to Standard, the next sweep that visits the title lifts
  # any anime hold.
  defp anime_hold_fix("original_language_required"), do: {:attention, :detail_page}
  defp anime_hold_fix("subtitle_language_required"), do: {:attention, :subtitle_settings}
  defp anime_hold_fix(_unknown), do: {:attention, :detail_page}

  defp verification_hold?(%Movie{status: :import_failed, verification_hold_origin: origin}),
    do: origin in [:download, :upgrade]

  defp verification_hold?(%Movie{}), do: false

  # A fresh-download hold is cancelled; an upgrade hold is aborted back to its live file.
  defp hold_release(%Movie{verification_hold_origin: :download}), do: :cancel
  defp hold_release(%Movie{verification_hold_origin: :upgrade}), do: :cancel_upgrade

  defp attention(reason, badge, actions),
    do: %__MODULE__{phase: :attention, reason: reason, badge: badge, actions: actions}

  defp active(badge, actions), do: %__MODULE__{phase: :active, badge: badge, actions: actions}
end
