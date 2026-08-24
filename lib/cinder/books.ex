defmodule Cinder.Books do
  @moduledoc "The provider-neutral books catalog and per-media-kind monitoring targets."

  import Ecto.Query

  alias Cinder.Books.{
    Author,
    BookTarget,
    BookTargetTransition,
    Credit,
    Edition,
    Identifier,
    SeriesMembership,
    Work
  }

  alias Cinder.LibraryKind
  alias Cinder.Repo

  @book_media_kinds LibraryKind.all() -- LibraryKind.video()
  @targets_topic "book_targets"
  @work_preloads [
    :identifiers,
    :series_memberships,
    :targets,
    credits: [:author],
    editions: [:identifiers, credits: [:author]]
  ]

  def upsert_author(attrs),
    do: upsert_by_identifier(Author, :author_id, %Author{}, attrs, &Author.changeset/2)

  def upsert_work(attrs),
    do: upsert_by_identifier(Work, :work_id, %Work{}, attrs, &Work.changeset/2)

  def upsert_edition(attrs) do
    attrs = attrs |> Map.new() |> Map.put_new(:work_id, nil)
    work_id = Map.fetch!(attrs, :work_id)

    upsert_by_identifier(
      Edition,
      :edition_id,
      %Edition{work_id: work_id},
      attrs,
      &Edition.changeset/2
    )
  end

  def put_identifier(%Author{id: id}, attrs),
    do: insert_identifier(%Identifier{author_id: id}, attrs)

  def put_identifier(%Work{id: id}, attrs),
    do: insert_identifier(%Identifier{work_id: id}, attrs)

  def put_identifier(%Edition{id: id}, attrs),
    do: insert_identifier(%Identifier{edition_id: id}, attrs)

  def put_credit(%Work{id: id}, attrs),
    do: insert_credit(%Credit{work_id: id}, attrs)

  def put_credit(%Edition{id: id}, attrs),
    do: insert_credit(%Credit{edition_id: id}, attrs)

  def put_series_membership(%Work{id: id}, attrs) do
    attrs = Map.new(attrs)

    %SeriesMembership{work_id: id}
    |> SeriesMembership.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Fetches a work with identifiers, ordered credits and their authors, series memberships,
  targets, and editions with their own identifiers and ordered credits/authors preloaded.
  """
  def get_work(id) do
    case Repo.get(Work, id) do
      nil -> nil
      work -> Repo.preload(work, @work_preloads)
    end
  end

  def list_targets(%Work{id: id}) do
    Repo.all(from t in BookTarget, where: t.work_id == ^id, order_by: [asc: t.media_kind])
  end

  def ensure_target(%Work{id: id}, media_kind) when media_kind in @book_media_kinds do
    result =
      %BookTarget{work_id: id}
      |> BookTarget.create_changeset(%{media_kind: media_kind})
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:work_id, :media_kind])

    case result do
      {:ok, _target} -> {:ok, Repo.get_by!(BookTarget, work_id: id, media_kind: media_kind)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def transition_target(%BookTarget{} = target, attrs, expect: expected),
    do: BookTargetTransition.guarded(target, attrs, expected)

  @doc "Subscribes the caller to `{:book_target_updated, target}` broadcasts."
  def subscribe_targets, do: Phoenix.PubSub.subscribe(Cinder.PubSub, @targets_topic)

  @doc false
  def broadcast(message), do: Phoenix.PubSub.broadcast(Cinder.PubSub, @targets_topic, message)

  defp upsert_by_identifier(schema, subject_key, initial, attrs, changeset_fun) do
    attrs = Map.new(attrs)
    identifier_attrs = attrs |> Map.fetch!(:identifier) |> Map.new()

    # Take the write lock before lookup so concurrent upserts cannot share a stale snapshot.
    Repo.transaction(
      fn ->
        case Repo.get_by(
               Identifier,
               provider: Map.fetch!(identifier_attrs, :provider),
               kind: Map.fetch!(identifier_attrs, :kind),
               foreign_id: Map.fetch!(identifier_attrs, :foreign_id)
             ) do
          nil -> insert_subject(initial, attrs, identifier_attrs, changeset_fun)
          identifier -> update_subject(schema, subject_key, identifier, attrs, changeset_fun)
        end
      end,
      mode: :immediate
    )
  end

  defp insert_subject(initial, attrs, identifier_attrs, changeset_fun) do
    with {:ok, subject} <- initial |> changeset_fun.(attrs) |> Repo.insert(),
         {:ok, _identifier} <- put_identifier(subject, identifier_attrs) do
      subject
    else
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp update_subject(
         Edition,
         :edition_id,
         %{edition_id: id},
         %{work_id: work_id} = attrs,
         changeset_fun
       )
       when not is_nil(id) do
    case Repo.get!(Edition, id) do
      %Edition{work_id: ^work_id} = edition ->
        edition |> changeset_fun.(attrs) |> update_or_rollback()

      %Edition{} ->
        Repo.rollback(:identifier_subject_mismatch)
    end
  end

  defp update_subject(schema, subject_key, identifier, attrs, changeset_fun) do
    case Map.fetch!(identifier, subject_key) do
      nil -> Repo.rollback(:identifier_subject_mismatch)
      id -> schema |> Repo.get!(id) |> changeset_fun.(attrs) |> update_or_rollback()
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, subject} -> subject
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp insert_identifier(identifier, attrs) do
    identifier
    |> Identifier.changeset(Map.new(attrs))
    |> Repo.insert()
  end

  defp insert_credit(%Credit{} = credit, attrs) do
    attrs = Map.new(attrs)

    %Credit{credit | author_id: Map.get(attrs, :author_id)}
    |> Credit.changeset(attrs)
    |> Repo.insert()
  end
end
