defmodule Cinder.Repo.Migrations.AddReleaseSizeToInFlightRows do
  use Ecto.Migration

  # #1587: the grab disk guard subtracts the bytes in-flight downloads still have to write, so each
  # row that owns a download records its release's size. Nil means the size is unknown (a grab from
  # before this migration, or an indexer that reported none), and such a row reserves nothing.
  def change do
    for table <- [:movies, :grabs, :book_grabs] do
      alter table(table) do
        add :release_size, :integer
      end
    end
  end
end
