defmodule Cinder.Repo.Migrations.AddBookRequests do
  use Ecto.Migration

  # A book request is `target_type = 'book'`, `target_id = book_works.id`, plus `media_kind`.
  #
  # Two existing structures have to learn that third target type:
  #
  # * `requests_pending_unique` — without `media_kind` in the key, one requester could not have an
  #   eBook and an audiobook request open for the same work.
  # * `requests_profile_integrity_*` and `media_profiles_references_integrity_update` — their
  #   `requests` arm matches only movie/series target types, so a book request carrying a book
  #   profile would hit NOT EXISTS on every arm and ABORT. `handling = proposed_media_profile`
  #   stays common to all arms: book profiles are `standard` only.

  def up do
    alter table(:requests) do
      add :media_kind, :string
    end

    execute "DROP INDEX IF EXISTS requests_pending_unique"

    create unique_index(
             :requests,
             [
               :user_id,
               :target_type,
               :target_id,
               "COALESCE(season_number, -1)",
               "COALESCE(media_kind, '')"
             ],
             name: :requests_pending_unique,
             where: "status = 'pending'"
           )

    drop_request_triggers()
    create_request_profile_integrity_trigger("INSERT", book_arm: true)

    create_request_profile_integrity_trigger(
      "UPDATE OF proposed_profile_id, proposed_media_profile, target_type, media_kind",
      book_arm: true
    )

    create_references_integrity_trigger(book_arm: true)
  end

  def down do
    ensure_no_book_requests!()

    drop_request_triggers()
    create_request_profile_integrity_trigger("INSERT", book_arm: false)

    create_request_profile_integrity_trigger(
      "UPDATE OF proposed_profile_id, proposed_media_profile, target_type",
      book_arm: false
    )

    create_references_integrity_trigger(book_arm: false)

    execute "DROP INDEX IF EXISTS requests_pending_unique"

    create unique_index(
             :requests,
             [:user_id, :target_type, :target_id, "COALESCE(season_number, -1)"],
             name: :requests_pending_unique,
             where: "status = 'pending'"
           )

    alter table(:requests) do
      remove :media_kind
    end
  end

  defp drop_request_triggers do
    for suffix <- ["insert", "update"] do
      execute "DROP TRIGGER IF EXISTS requests_profile_integrity_#{suffix}"
    end

    execute "DROP TRIGGER IF EXISTS media_profiles_references_integrity_update"
  end

  # Inside this trigger the unqualified `kind` is the candidate media_profiles row and `NEW.*`
  # is the request being written.
  defp create_request_profile_integrity_trigger(event, book_arm: book_arm?) do
    suffix = if event == "INSERT", do: "insert", else: "update"

    book_arm =
      if book_arm?,
        do: " OR\n            (NEW.target_type = 'book' AND kind = NEW.media_kind)",
        else: ""

    execute("""
    CREATE TRIGGER requests_profile_integrity_#{suffix}
    BEFORE #{event} ON requests
    WHEN NEW.proposed_profile_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM media_profiles
      WHERE id = NEW.proposed_profile_id
        AND handling = NEW.proposed_media_profile
        AND (
          (NEW.target_type = 'movie' AND kind = 'movies') OR
          (NEW.target_type IN ('series', 'season', 'episode') AND kind = 'tv')#{book_arm}
        )
    )
    BEGIN
      SELECT RAISE(ABORT, 'CHECK constraint failed: requests_profile_integrity');
    END
    """)
  end

  # Here `NEW.kind` is the profile's new kind and the unqualified columns are the correlated
  # requests/book_targets rows still pointing at it.
  defp create_references_integrity_trigger(book_arm: book_arm?) do
    book_arm =
      if book_arm?,
        do: " OR\n              (target_type = 'book' AND NEW.kind = media_kind)",
        else: ""

    execute("""
    CREATE TRIGGER media_profiles_references_integrity_update
    BEFORE UPDATE OF kind, handling ON media_profiles
    WHEN
      EXISTS (
        SELECT 1 FROM movies
        WHERE profile_id = OLD.id
          AND (NEW.kind != 'movies' OR NEW.handling != media_profile)
      ) OR
      EXISTS (
        SELECT 1 FROM series
        WHERE profile_id = OLD.id
          AND (NEW.kind != 'tv' OR NEW.handling != media_profile)
      ) OR
      EXISTS (
        SELECT 1 FROM requests
        WHERE proposed_profile_id = OLD.id
          AND (
            NEW.handling != proposed_media_profile OR
            NOT (
              (target_type = 'movie' AND NEW.kind = 'movies') OR
              (target_type IN ('series', 'season', 'episode') AND NEW.kind = 'tv')#{book_arm}
            )
          )
      ) OR
      EXISTS (
        SELECT 1 FROM book_targets
        WHERE profile_id = OLD.id
          AND NEW.kind != media_kind
      )
    BEGIN
      SELECT RAISE(ABORT, 'CHECK constraint failed: media_profiles_references_integrity');
    END
    """)
  end

  defp ensure_no_book_requests! do
    case repo().query!("SELECT id FROM requests WHERE target_type = 'book' LIMIT 1").rows do
      [] -> :ok
      [[id]] -> raise "cannot roll back book requests while request #{id} exists"
    end
  end
end
