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

  @book_media_kinds LibraryKind.books()
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

  @doc """
  Works with at least one monitoring target, identifiers preloaded — the refresh set.
  """
  def list_works_for_refresh do
    Repo.all(
      from w in Work,
        join: t in assoc(w, :targets),
        distinct: true,
        order_by: [asc: w.id],
        preload: [:identifiers]
    )
  end

  @doc """
  Folds a `Cinder.Books.Identity` resolution into the catalog in one transaction: the work and its
  provider identifier, each identified contributor as an author plus an ordered credit, the digital
  editions with their own identifiers and normalized ISBN/ASIN, and the series memberships.

  Idempotent. Everything is keyed off `book_identifiers`, so re-importing the same work — from the
  same provider, from the other one, or with a different ISBN in the payload — updates in place
  rather than duplicating.

  **Only fields the provider actually returned are written.** A payload missing `overview` leaves
  an existing overview alone instead of nilling it, which is what makes a partial or degraded
  provider response safe to import. Credits and series memberships are the exception: they are
  replaced wholesale, so a work's contributor list is always exactly what the last successful
  import said rather than an accreted union of every provider that ever ran.

  A contributor the provider named but did not identify is dropped, not invented, and the work is
  flagged `contributors_incomplete`.
  """
  def import_resolution(%{work: work, provider: provider}) do
    Repo.transaction(fn -> import_work(work, to_string(provider)) end, mode: :immediate)
  end

  defp import_work(work, provider) do
    {contributors, dropped?} = identified_contributors(work.contributors)

    attrs =
      %{
        title: work.title,
        first_published_on: work.first_published_on,
        overview: work.overview,
        contributors_incomplete: work.contributors_incomplete or dropped?
      }
      |> drop_nils()
      |> Map.put(:identifier, %{provider: provider, kind: "work", foreign_id: work.foreign_id})

    record = upsert_in_tx(Work, :work_id, %Work{}, attrs, &Work.changeset/2)

    put_credits(record, contributors, provider)
    put_series(record, work.series, provider)
    Enum.each(work.editions, &put_edition(record, &1, provider))

    record
  end

  # A contributor with no provider id cannot be identified across refreshes, and the contract
  # forbids inventing one. Drop it and let `contributors_incomplete` carry the signal.
  defp identified_contributors(contributors) do
    identified =
      contributors
      |> Enum.filter(&present?(&1.foreign_id))
      |> Enum.uniq_by(&{&1.foreign_id, &1.role})

    {identified, length(identified) != length(contributors)}
  end

  defp put_credits(work, contributors, provider) do
    Repo.delete_all(from c in Credit, where: c.work_id == ^work.id)

    contributors
    |> Enum.with_index()
    |> Enum.each(fn {contributor, position} ->
      author =
        upsert_in_tx(
          Author,
          :author_id,
          %Author{},
          %{
            name: contributor.name,
            identifier: %{
              provider: provider,
              kind: "author",
              foreign_id: contributor.foreign_id
            }
          },
          &Author.changeset/2
        )

      work
      |> put_credit(%{author_id: author.id, role: contributor.role, position: position})
      |> or_rollback()
    end)
  end

  defp put_series(work, series, provider) do
    Repo.delete_all(from m in SeriesMembership, where: m.work_id == ^work.id)

    series
    |> Enum.uniq_by(& &1.name)
    |> Enum.each(fn entry ->
      work
      |> put_series_membership(%{name: entry.name, position: entry.position, provider: provider})
      |> or_rollback()
    end)
  end

  defp put_edition(work, edition, provider) do
    attrs =
      %{
        media_kind: edition.media_kind,
        title: edition.title,
        language: edition.language,
        format: edition.format,
        publisher: edition.publisher,
        release_date: edition.release_date,
        abridged: edition.abridged
      }
      |> drop_nils()
      |> Map.merge(%{
        work_id: work.id,
        identifier: %{provider: provider, kind: "edition", foreign_id: edition.foreign_id}
      })

    record =
      upsert_in_tx(
        Edition,
        :edition_id,
        %Edition{work_id: work.id},
        attrs,
        &Edition.changeset/2
      )

    put_normalized_identifier(record, "isbn", "isbn13", edition.isbn13)
    put_normalized_identifier(record, "asin", "asin", edition.asin)
  end

  # ISBN/ASIN are stored normalized, so "978-1-4000-3341-6" and "9781400033416" are one identifier
  # rather than two rows nothing can join on.
  #
  # on_conflict: :nothing — an ISBN already recorded against a different edition keeps pointing
  # where it is. Re-pointing a normalized identifier is an identity change, and the contract wants
  # those backed by evidence, not by whichever provider ran last.
  defp put_normalized_identifier(edition, provider, kind, value) do
    case normalize_identifier(value) do
      nil ->
        :ok

      normalized ->
        insert_identifier(
          %Identifier{edition_id: edition.id},
          %{provider: provider, kind: kind, foreign_id: normalized},
          on_conflict: :nothing,
          conflict_target: [:provider, :kind, :foreign_id]
        )
    end
  end

  defp normalize_identifier(value) when is_binary(value) do
    case value |> String.upcase() |> String.replace(~r/[^0-9A-Z]/, "") do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_identifier(_value), do: nil

  defp or_rollback({:ok, record}), do: record
  defp or_rollback({:error, changeset}), do: Repo.rollback(changeset)

  defp drop_nils(attrs), do: Map.reject(attrs, fn {_key, value} -> is_nil(value) end)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # Take the write lock before lookup so concurrent upserts cannot share a stale snapshot.
  defp upsert_by_identifier(schema, subject_key, initial, attrs, changeset_fun) do
    Repo.transaction(
      fn -> upsert_in_tx(schema, subject_key, initial, attrs, changeset_fun) end,
      mode: :immediate
    )
  end

  # The body of `upsert_by_identifier/5` without its transaction, so `import_resolution/1` can
  # fold a whole work — author, work, editions, identifiers — into one.
  defp upsert_in_tx(schema, subject_key, initial, attrs, changeset_fun) do
    attrs = Map.new(attrs)
    identifier_attrs = attrs |> Map.fetch!(:identifier) |> Map.new()

    case Repo.get_by(
           Identifier,
           provider: Map.fetch!(identifier_attrs, :provider),
           kind: Map.fetch!(identifier_attrs, :kind),
           foreign_id: Map.fetch!(identifier_attrs, :foreign_id)
         ) do
      nil -> insert_subject(initial, attrs, identifier_attrs, changeset_fun)
      identifier -> update_subject(schema, subject_key, identifier, attrs, changeset_fun)
    end
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

  defp insert_identifier(identifier, attrs, opts \\ []) do
    identifier
    |> Identifier.changeset(Map.new(attrs))
    |> Repo.insert(opts)
  end

  defp insert_credit(%Credit{} = credit, attrs) do
    attrs = Map.new(attrs)

    %Credit{credit | author_id: Map.get(attrs, :author_id)}
    |> Credit.changeset(attrs)
    |> Repo.insert()
  end
end
