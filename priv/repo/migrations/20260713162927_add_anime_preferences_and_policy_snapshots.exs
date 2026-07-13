defmodule Cinder.Repo.Migrations.AddAnimePreferencesAndPolicySnapshots do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      add :audio_mode, :string
      add :subtitle_languages, {:array, :string}
      add :embedded_subtitle_mode, :string
      add :preferred_release_groups, {:array, :string}
      add :blocked_release_groups, {:array, :string}
      add :group_fallback_delay, :integer
    end

    alter table(:series) do
      add :audio_mode, :string
      add :subtitle_languages, {:array, :string}
      add :embedded_subtitle_mode, :string
      add :preferred_release_groups, {:array, :string}
      add :blocked_release_groups, {:array, :string}
      add :group_fallback_delay, :integer
    end

    alter table(:movies), do: add(:release_policy_snapshot, :map)
    alter table(:download_intents), do: add(:release_policy_snapshot, :map)
    alter table(:grabs), do: add(:release_policy_snapshot, :map)
  end
end
