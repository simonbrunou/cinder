defmodule CinderWeb.DiscoverComponents do
  @moduledoc """
  Shared Discover markup: the poster grid and its per-type action slot (movie Add
  form, TV season-picker link, person/collection View button), used by both
  `DiscoverLive` and `EntityDiscoveryLive`. `use CinderWeb, :html` — brings
  VerifiedRoutes (`~p`) and gettext, which `CoreComponents` doesn't otherwise need.
  """
  use CinderWeb, :html

  attr :id, :string, required: true
  attr :results, :list, required: true
  attr :request_status, :map, required: true
  attr :movie_status, :map, required: true
  attr :series_request_status, :map, required: true
  attr :available_series, :any, required: true

  # One grid for search results, trending, person credits, and collection parts alike.
  def media_grid(assigns) do
    ~H"""
    <div id={@id} class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-4">
      <.media_card
        :for={r <- @results}
        poster_path={r.poster_path}
        title={r.title}
        year={r.year}
        type={r.type}
      >
        <.result_action
          :if={r.type == :movie}
          state={title_state(r.tmdb_id, @request_status, @movie_status)}
          tmdb_id={r.tmdb_id}
          title={r.title}
          original_language={r.original_language}
        />
        <.tv_result_action
          :if={r.type == :tv}
          state={tv_title_state(r.tmdb_id, @series_request_status, @available_series)}
          tmdb_id={r.tmdb_id}
        />
        <.person_result_action
          :if={r.type == :person}
          tmdb_id={r.tmdb_id}
          title={r.title}
          department={r.department}
        />
        <.collection_result_action :if={r.type == :collection} tmdb_id={r.tmdb_id} title={r.title} />
      </.media_card>
    </div>
    """
  end

  attr :state, :atom, required: true
  attr :tmdb_id, :integer, required: true
  attr :title, :string, required: true
  attr :original_language, :string, default: nil

  defp result_action(assigns) do
    ~H"""
    <.status_badge
      :if={@state != :none}
      kind={:request}
      status={@state}
      class="h-auto break-words text-center"
    />
    <form
      :if={@state in [:none, :denied]}
      id={"add-form-#{@tmdb_id}"}
      phx-submit="add"
      class="flex flex-col gap-1"
    >
      <input type="hidden" name="tmdb_id" value={@tmdb_id} />
      <.language_select original_label={original_option_label(@original_language)} />
      <.media_profile_select />
      <.button
        type="submit"
        variant="primary"
        size="sm"
        class="w-full"
        aria-label={gettext("Add %{title}", title: @title)}
        phx-disable-with={gettext("Adding…")}
      >
        {gettext("Add")}
      </.button>
    </form>
    """
  end

  attr :state, :atom, required: true
  attr :tmdb_id, :integer, required: true

  # TV cards keep the season-picker link always (a show can be re-browsed for more seasons); the
  # badge is additive, unlike the movie card where an active state replaces the Add form.
  defp tv_result_action(assigns) do
    ~H"""
    <.status_badge
      :if={@state != :none}
      kind={:request}
      status={@state}
      class="h-auto break-words text-center"
    />
    <.button navigate={~p"/series/tmdb/#{@tmdb_id}"} variant="primary" size="sm" class="w-full">
      {gettext("View seasons")}<.icon name="hero-arrow-right" class="size-3.5" />
    </.button>
    """
  end

  attr :tmdb_id, :integer, required: true
  attr :title, :string, required: true
  attr :department, :string, default: nil

  defp person_result_action(assigns) do
    ~H"""
    <p :if={@department} class="text-xs text-base-content/70">{department_label(@department)}</p>
    <.button
      navigate={~p"/person/tmdb/#{@tmdb_id}"}
      variant="primary"
      size="sm"
      class="w-full"
      aria-label={gettext("View %{title}", title: @title)}
    >
      {gettext("View")}<.icon name="hero-arrow-right" class="size-3.5" />
    </.button>
    """
  end

  attr :tmdb_id, :integer, required: true
  attr :title, :string, required: true

  defp collection_result_action(assigns) do
    ~H"""
    <.button
      navigate={~p"/collection/tmdb/#{@tmdb_id}"}
      variant="primary"
      size="sm"
      class="w-full"
      aria-label={gettext("View %{title}", title: @title)}
    >
      {gettext("View")}<.icon name="hero-arrow-right" class="size-3.5" />
    </.button>
    """
  end

  defp original_option_label(nil), do: gettext("Original")
  defp original_option_label("en"), do: gettext("Original (English)")
  defp original_option_label("fr"), do: gettext("Original (French)")
  defp original_option_label(_), do: gettext("Original")

  @doc """
  Human label for a TMDB `known_for_department`/`department` value (the app is
  bilingual, so this is a full map over TMDB's ~12 department values, not a
  2-case one); an unmapped value passes through raw rather than crashing.
  Public — also used by `EntityDiscoveryLive`'s person header.
  """
  def department_label("Acting"), do: gettext("Actor")
  def department_label("Directing"), do: gettext("Director")
  def department_label("Writing"), do: gettext("Writer")
  def department_label("Production"), do: gettext("Producer")
  def department_label("Sound"), do: gettext("Sound")
  def department_label("Camera"), do: gettext("Camera")
  def department_label("Art"), do: gettext("Art")
  def department_label("Editing"), do: gettext("Editing")
  def department_label("Costume & Make-Up"), do: gettext("Costume & Make-Up")
  def department_label("Visual Effects"), do: gettext("Visual Effects")
  def department_label("Crew"), do: gettext("Crew")
  def department_label("Lighting"), do: gettext("Lighting")
  def department_label(other), do: other

  # Precedence: an available movie outranks a stale denied/approved request. An
  # `:upgrading` movie still has a playable library file, so it reads as available
  # (and must not re-show the Request affordance).
  defp title_state(tmdb_id, request_status, movie_status) do
    cond do
      movie_status[tmdb_id] in [:available, :upgrading] -> :available
      request_status[tmdb_id] == :pending -> :pending
      request_status[tmdb_id] == :approved -> :approved
      request_status[tmdb_id] == :denied -> :denied
      true -> :none
    end
  end

  # Series-level composite for a TV card, same precedence as title_state/3 but sourced from the
  # user's season requests (keyed by series tmdb_id) and season availability.
  defp tv_title_state(tmdb_id, series_request_status, available_series) do
    cond do
      MapSet.member?(available_series, tmdb_id) -> :available
      series_request_status[tmdb_id] == :pending -> :pending
      series_request_status[tmdb_id] == :approved -> :approved
      series_request_status[tmdb_id] == :denied -> :denied
      true -> :none
    end
  end
end
