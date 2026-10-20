defmodule Cinder.Requests.Approval.Book do
  @moduledoc false
  # The book adapter of `Cinder.Requests.Approval`. No provider round-trip and no catalog row to
  # create: the work already exists, so approving arms its target for the requested media kind.
  @behaviour Cinder.Requests.Approval

  alias Cinder.Books
  alias Cinder.Books.Work
  alias Cinder.Catalog.Profile
  alias Cinder.Repo

  @impl true
  def prepare(source, _profile) do
    case Repo.get(Work, source.target_id) do
      %Work{} = work -> {:ok, {work, Map.get(source, :media_kind)}}
      nil -> {:error, :unknown_work}
    end
  end

  # A book target is useless without a profile: B4 has nothing to score against.
  @impl true
  def create({work, media_kind}, %Profile{} = profile),
    do: Books.monitor_target(work, media_kind, profile, publish: false)

  def create(_prepared, nil), do: {:error, :invalid_media_profile}

  @impl true
  def publish(target, _approved) do
    Books.broadcast({:book_target_updated, target})
    :ok
  end
end
