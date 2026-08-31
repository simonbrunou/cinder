defmodule Cinder.Repo.Migrations.CreateBookGrabsAndFiles do
  use Ecto.Migration

  def change do
    # In-flight download state for one book target. Deliberately NOT more columns on
    # `book_targets`: the parity contract locks that table's status vocabulary to
    # unmonitored/monitored/available/held, so there is no `:downloading` to move it to. A target
    # stays `:monitored` for the whole download and the grab row carries the transient state.
    create table(:book_grabs) do
      add :book_target_id, references(:book_targets, on_delete: :delete_all), null: false
      add :download_id, :string, null: false

      add :download_protocol, :string,
        null: false,
        check: %{
          name: "book_grabs_download_protocol_valid",
          expr: "download_protocol IN ('torrent', 'usenet')"
        }

      add :release_title, :string
      add :content_path, :string
      add :import_attempts, :integer, null: false, default: 0
      add :download_progress, :float
      add :download_speed, :integer
      add :download_eta, :integer
      add :download_progress_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # One in-flight download per target. This index is what makes a repeated poll tick unable to
    # double-grab: the second insert fails rather than producing a second client submission.
    create unique_index(:book_grabs, [:book_target_id])

    # One imported asset. `edition_id` is nullable ON PURPOSE: the contract's File boundary belongs
    # to an edition, but it also forbids resolving identity from "a title, ISBN, ASIN, path, or
    # filename alone", and a release name usually cannot name an edition. A null is the contract's
    # "explicitly incomplete" signal — inventing an edition to satisfy a foreign key would be the
    # silent fallback the contract exists to prevent.
    create table(:book_files) do
      add :book_target_id, references(:book_targets, on_delete: :delete_all), null: false
      add :edition_id, references(:book_editions, on_delete: :nilify_all)
      add :path, :string, null: false
      add :size, :integer

      add :format, :string,
        null: false,
        check: %{
          name: "book_files_format_valid",
          expr: "format IN ('epub', 'azw3', 'mobi')"
        }

      timestamps(type: :utc_datetime)
    end

    create unique_index(:book_files, [:path])
    create index(:book_files, [:book_target_id])
    create index(:book_files, [:edition_id])

    # A book target's durable download reservation reuses `download_intents` — the same
    # pre-side-effect journal, encrypted URL, bounded retry, and operation-key recovery the movie
    # and TV paths already use. The partial index mirrors `download_intents_movie_target_index`:
    # `target_id` alone is not unique across kinds (it is a movies.id for one kind and a
    # book_targets.id for the other), so the uniqueness has to be scoped by kind.
    create unique_index(:download_intents, [:target_id],
             where: "kind = 'book_target'",
             name: :download_intents_book_target_index
           )
  end
end
