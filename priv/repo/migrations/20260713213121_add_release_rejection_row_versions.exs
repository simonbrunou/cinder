defmodule Cinder.Repo.Migrations.AddReleaseRejectionRowVersions do
  use Ecto.Migration

  def up do
    alter table(:movies) do
      add :row_version, :integer, null: false, default: 1
    end

    alter table(:grabs) do
      add :row_version, :integer, null: false, default: 1
    end

    execute("""
    CREATE TRIGGER movies_bump_row_version
    AFTER UPDATE ON movies
    FOR EACH ROW
    WHEN NEW.row_version = OLD.row_version
    BEGIN
      UPDATE movies
      SET row_version = OLD.row_version + 1
      WHERE id = OLD.id;
    END
    """)

    execute("""
    CREATE TRIGGER grabs_bump_row_version
    AFTER UPDATE ON grabs
    FOR EACH ROW
    WHEN NEW.row_version = OLD.row_version
    BEGIN
      UPDATE grabs
      SET row_version = OLD.row_version + 1
      WHERE id = OLD.id;
    END
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS movies_bump_row_version")
    execute("DROP TRIGGER IF EXISTS grabs_bump_row_version")

    alter table(:movies) do
      remove :row_version
    end

    alter table(:grabs) do
      remove :row_version
    end
  end
end
