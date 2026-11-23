defmodule Cinder.Download.GrabReserve do
  @moduledoc """
  The bytes that in-flight downloads still have to write, which the grab disk guard subtracts from
  a download root's free space (`Cinder.Download.grab_space_available?/1`).

  A download counts as its recorded release size times `1 - download_progress`, with a nil
  progress read as 0 and the progress clamped to 0..1. These rows count:

    * a TV grab or a book grab whose `content_path` is nil;
    * a `:downloading` movie, or an `:upgrading` movie with a `download_id`. An upgrade keeps
      `content_path` nil until it imports, so only its progress lowers what it reserves;
    * a `:submitted` intent whose `remote_id` no TV grab, book grab or movie holds on the same
      protocol. For a movie, a book or a TV grab with no snapshots, `Cinder.Download` writes the
      owner row and then deletes the intent in a separate step, so a crash between the two leaves
      both. The owner row alone then decides what that download reserves.
      `Catalog.create_grab_from_intent/1` writes the grab and deletes the intent in one
      transaction.

  Every other row reserves nothing, a row with no recorded size included, so the result is an
  estimate from the sizes Cinder recorded.

  Rows sharing a `download_id` on one protocol are one download, since a duplicate add can return
  the existing job's id (Transmission's `torrent-duplicate`, qBittorrent's 409). That download
  counts once, at the largest amount any of its rows reserves. A row with no `download_id` counts
  on its own.

  The rows are read in one `UNION ALL` statement, so an owner write landing between two reads can
  neither hide a download nor count it twice. A transaction would take SQLite's write lock here
  (`default_transaction_mode: :immediate`). The read has no rescue: when the database cannot
  answer, the error reaches the caller, as it does for the intent the grab writes right after.
  """

  import Ecto.Query

  alias Cinder.Books.BookGrab
  alias Cinder.Catalog.{Grab, Movie}
  alias Cinder.Download.Intent
  alias Cinder.Repo

  @doc "The bytes in-flight downloads still have to write. See the moduledoc for what counts."
  @spec bytes() :: non_neg_integer()
  def bytes do
    Grab
    |> unfinished_grabs()
    |> union_all(^unfinished_grabs(BookGrab))
    |> union_all(^movies())
    |> union_all(^submitted_intents())
    |> Repo.all()
    |> Enum.reduce(%{}, fn {id, protocol, size, progress}, downloads ->
      bytes = remaining(size, progress)
      Map.update(downloads, download_key(id, protocol), bytes, &max(&1, bytes))
    end)
    |> Map.values()
    |> Enum.sum()
  end

  defp download_key(nil, _protocol), do: make_ref()
  defp download_key(id, protocol), do: {id, protocol || :torrent}

  defp remaining(size, progress), do: ceil(size * (1 - fraction(progress)))

  defp fraction(nil), do: 0
  defp fraction(progress), do: progress |> max(0) |> min(1)

  defp unfinished_grabs(schema) do
    from g in schema,
      where: is_nil(g.content_path) and g.release_size > 0,
      select: {g.download_id, g.download_protocol, g.release_size, g.download_progress}
  end

  defp movies do
    from m in Movie,
      where:
        m.release_size > 0 and
          (m.status == :downloading or (m.status == :upgrading and not is_nil(m.download_id))),
      select: {m.download_id, m.download_protocol, m.release_size, m.download_progress}
  end

  # A movie row from before `download_protocol` existed has a nil protocol, which
  # `Cinder.Download.client_for/1` reads as `:torrent`.
  defp submitted_intents do
    from i in Intent,
      as: :intent,
      where: i.status == :submitted,
      where: fragment("json_type(?, '$.size') = 'integer'", i.release),
      where: fragment("json_extract(?, '$.size') > 0", i.release),
      where:
        not exists(
          from g in Grab,
            where:
              g.download_id == parent_as(:intent).remote_id and
                g.download_protocol == parent_as(:intent).protocol,
            select: 1
        ),
      where:
        not exists(
          from g in BookGrab,
            where:
              g.download_id == parent_as(:intent).remote_id and
                g.download_protocol == parent_as(:intent).protocol,
            select: 1
        ),
      where:
        not exists(
          from m in Movie,
            where:
              m.download_id == parent_as(:intent).remote_id and
                fragment(
                  "coalesce(?, 'torrent') = ?",
                  m.download_protocol,
                  parent_as(:intent).protocol
                ),
            select: 1
        ),
      select:
        {i.remote_id, i.protocol, fragment("json_extract(?, '$.size')", i.release),
         fragment("NULL")}
  end
end
