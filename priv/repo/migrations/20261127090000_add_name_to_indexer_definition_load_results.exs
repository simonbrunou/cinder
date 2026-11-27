defmodule Cinder.Repo.Migrations.AddNameToIndexerDefinitionLoadResults do
  use Ecto.Migration

  # The display name of a copy that parses (#1676), which the add list of /settings shows. The
  # loader's revision 9 makes every stored result stale, so the boot re-check fills it in.
  def change do
    alter table(:indexer_definition_load_results) do
      add :name, :string
    end
  end
end
