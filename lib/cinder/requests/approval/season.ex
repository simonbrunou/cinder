defmodule Cinder.Requests.Approval.Season do
  @moduledoc false
  # The season adapter of `Cinder.Requests.Approval`: approving one season creates the series if
  # Cinder has none yet, and monitors only that season.
  @behaviour Cinder.Requests.Approval

  alias Cinder.Catalog
  alias Cinder.Requests.Approval

  @impl true
  def prepare(source, profile) do
    preferred = Map.get(source, :preferred_language) || "original"

    with {:ok, series} <-
           Catalog.prepare_requested_series(
             source.target_id,
             preferred,
             Approval.handling(profile)
           ) do
      {:ok,
       %{series: series, season_number: Map.get(source, :season_number), preferred: preferred}}
    end
  end

  @impl true
  def create(prepared, profile) do
    with {:ok, series} <-
           Catalog.persist_requested_series(
             prepared.series,
             prepared.season_number,
             prepared.preferred,
             Approval.handling(profile)
           ),
         {:ok, {series, _profile_changed?}} <- Approval.assign_selected_profile(series, profile) do
      {:ok, series}
    end
  end

  @impl true
  def publish(series, _approved) do
    Catalog.broadcast_series(series.id)
    :ok
  end
end
