defmodule Cinder.Requests.Approval.Movie do
  @moduledoc false
  # The movie adapter of `Cinder.Requests.Approval`.
  @behaviour Cinder.Requests.Approval

  require Logger
  alias Cinder.Catalog
  alias Cinder.Repo
  alias Cinder.Requests.Approval

  @impl true
  def prepare(source, profile) do
    Catalog.prepare_requested_movie(%{
      tmdb_id: Map.get(source, :target_id),
      title: Map.get(source, :title),
      year: Map.get(source, :year),
      poster_path: Map.get(source, :poster_path),
      original_language: Map.get(source, :original_language),
      preferred_language: Map.get(source, :preferred_language) || "original",
      media_profile: Approval.handling(profile),
      profile_id: profile && profile.id
    })
  end

  # Creation is announced post-commit, in publish/2: nothing here broadcasts.
  @impl true
  def create(prepared, profile) do
    with {:ok, movie, outcome} <-
           Catalog.find_or_create_at_requested(prepared.attrs, prepared.aliases),
         pre_request_profile = movie.media_profile,
         {:ok, {movie, profile_changed?}} <- Approval.assign_selected_profile(movie, profile) do
      {:ok,
       %{
         movie: movie,
         outcome: outcome,
         profile_changed?: profile_changed?,
         pre_request_profile: pre_request_profile,
         preferred: prepared.attrs.preferred_language
       }}
    end
  end

  # Runs AFTER the transaction commits. Catalog.apply_confirmed_media/4 must not run inside it: a
  # fill/confirm failure must not roll back the already-committed movie/request write. Both fields
  # stay detail-page-editable afterward, so a failure here only logs. Only an :existing movie is
  # confirmed/filled; a :created one needs neither.
  #
  # :created — a fresh insert already carries the requester's profile and pick (Movie.changeset
  # casts both from the create attrs), so there is nothing to confirm or fill: just announce.
  # Residual (accepted): the payload is the transaction's struct, so a delete landing in the
  # commit→broadcast gap would be announced after its own {:movie_deleted} and upserted back by
  # open views until remount — a sub-ms window that would cost a reload per fresh approval to close.
  @impl true
  def publish(%{outcome: :created, movie: movie}, _approved) do
    Catalog.broadcast_movie_created(movie)
    :ok
  end

  # :existing — re-read post-commit: the transaction's struct is a stale snapshot the moment it
  # commits, and an edit (or delete) landing before this reload wins over the requester's
  # confirm+fill. An edit in the reload→update window can still lose (no optimistic lock); accepted
  # at household scale.
  def publish(%{outcome: :existing, movie: movie} = created, approved) do
    case Repo.reload(movie) do
      nil ->
        Logger.warning("movie #{movie.id} (request #{approved.id}) deleted before confirm+fill")

      fresh ->
        confirm_and_fill(fresh, approved, created)
    end

    :ok
  end

  defp confirm_and_fill(movie, approved, %{
         preferred: preferred,
         pre_request_profile: pre_request_profile,
         profile_changed?: profile_changed?
       }) do
    fills_language? =
      movie.preferred_language == "original" and preferred not in [nil, "original"] and
        pre_request_profile != :anime

    result =
      if fills_language? do
        Catalog.apply_confirmed_media(movie, :auto, preferred, pre_request_profile)
      else
        {:ok, movie}
      end

    case result do
      {:ok, _movie} when profile_changed? and not fills_language? ->
        Catalog.broadcast({:movie_updated, movie})

      {:ok, _movie} ->
        :ok

      {:error, reason} ->
        if profile_changed?, do: Catalog.broadcast({:movie_updated, movie})

        Logger.warning(
          "apply_confirmed_media for movie #{movie.id} (request #{approved.id}) failed: " <>
            inspect(reason)
        )
    end
  end
end
