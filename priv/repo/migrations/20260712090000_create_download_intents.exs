defmodule Cinder.Repo.Migrations.CreateDownloadIntents do
  use Ecto.Migration

  def change do
    create table(:download_intents) do
      add :operation_key, :string, null: false
      add :kind, :string, null: false
      add :target_id, :integer, null: false
      add :episode_ids, {:array, :integer}, null: false, default: []
      add :protocol, :string, null: false
      add :release, :map, null: false
      add :status, :string, null: false, default: "reserved"
      add :remote_id, :string
      add :attempt_count, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime
      add :last_error, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:download_intents, [:operation_key])

    create unique_index(:download_intents, [:target_id],
             where: "kind = 'movie'",
             name: :download_intents_movie_target_index
           )

    create index(:download_intents, [:status])

    create table(:download_intent_episodes) do
      add :intent_id, references(:download_intents, on_delete: :delete_all), null: false
      add :episode_id, :integer, null: false
    end

    create unique_index(:download_intent_episodes, [:episode_id])
    create index(:download_intent_episodes, [:intent_id])
  end
end
