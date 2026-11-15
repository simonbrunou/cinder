defmodule Cinder.Repo.Migrations.AddLibraryCheckArmedAtToSeasons do
  use Ecto.Migration

  # #720: a season a request approval monitors is checked against the files already under the TV
  # library roots before the TV sweep first searches it. The column holds when the approval armed
  # that check; nil means no check is due. Every existing season starts with none.
  def change do
    alter table(:seasons) do
      add :library_check_armed_at, :utc_datetime
    end
  end
end
