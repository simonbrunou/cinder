defmodule Cinder.Acquisition.Indexer.CardigannFuzzytimeTest do
  # The `fuzzytime` filter and the date forms `DotnetDate.from_unknown/2` reads (#1802), through
  # the real `Cinder.Acquisition.IndexerSource.Native` and parser worker, on Nyaa-shaped
  # definitions (`Cinder.CardigannFixtures`) behind the `Cinder.CardigannStub` plug. Each expected
  # time is a row of DotnetDateFromUnknownTest moved to this module's clock.
  #
  # Not async: Native's clock is Native's global config.
  use Cinder.DataCase, async: false

  import Cinder.CardigannFixtures

  alias Cinder.Acquisition.IndexerSource.Native
  alias Cinder.ConfigCase

  # A Thursday.
  @now ~U[2026-11-26 12:00:00Z]

  setup do
    ConfigCase.put_env(Native, clock: fn -> @now end)
    :ok
  end

  defp frieren(dates) do
    for {date, i} <- Enum.with_index(dates, 1) do
      %{
        id: i,
        title: "[Group] Frieren - 0#{i} [1080p]",
        magnet: "magnet:?xt=urn:btih:#{String.duplicate(Integer.to_string(i), 40)}",
        size: "1.4 GiB",
        date: date,
        cat: "1_2"
      }
    end
  end

  # The definition with its `date` field replaced by `fields`.
  defp with_fields(fields) do
    fn definition ->
      update_in(definition, ["search", "fields"], &obj(replace_date(&1.values, fields)))
    end
  end

  defp replace_date(values, fields),
    do:
      Enum.flat_map(values, fn {key, _} = pair -> if key == "date", do: fields, else: [pair] end)

  defp nyaa!(edit) do
    [indexer] = setup!([{"nyaa.yml", nyaa_like(edit)}], [{"nyaa.yml", nyaa_base(), %{}}])
    indexer
  end

  defp dates(page) do
    route(%{"nyaa.test" => fn _conn, _query -> page end})
    assert {:ok, rows, _report} = Native.search_tv_query("frieren", categories: [5070])
    Enum.map(rows, &{&1.title, &1.published_at})
  end

  test "a date field with no filter reads Today, Yesterday and a day name with at" do
    nyaa!(with_fields([{"date", %{"selector" => "td:nth-child(5)"}}]))

    assert dates(nyaa_page(frieren(["Today 14:22", "Yesterday at 10:01 PM", "Monday at 14:22"]))) ==
             [
               {"[Group] Frieren - 01 [1080p]", ~U[2026-11-26 14:22:00Z]},
               {"[Group] Frieren - 02 [1080p]", ~U[2026-11-25 22:01:00Z]},
               {"[Group] Frieren - 03 [1080p]", ~U[2026-11-23 14:22:00Z]}
             ]
  end

  test "an optional fuzzytime field whose text fails reads nil, and the row goes on" do
    # Shaped like mikan.yml's date: the fuzzytime field, then a date that falls back without it.
    nyaa!(
      with_fields([
        {"date_day",
         %{
           "selector" => "td:nth-child(5)",
           "optional" => true,
           "filters" => [%{"name" => "fuzzytime"}]
         }},
        {"date",
         %{
           "text" =>
             "{{ if .Result.date_day }}{{ .Result.date_day }}{{ else }}2026-11-20T08:00:00Z{{ end }}"
         }}
      ])
    )

    assert dates(nyaa_page(frieren(["Yesterday 14:22 +08:00", "Today 14h22", "12:25am"]))) ==
             [
               {"[Group] Frieren - 01 [1080p]", ~U[2026-11-25 06:22:00Z]},
               {"[Group] Frieren - 02 [1080p]", ~U[2026-11-20 08:00:00Z]},
               {"[Group] Frieren - 03 [1080p]", ~U[2026-11-26 00:25:00Z]}
             ]
  end

  test "a date header with no filter reads Yesterday" do
    header = %{"selector" => "td[colspan] > b", "optional" => false, "filters" => []}
    nyaa!(&put_in(&1, ["search", "rows", "dateheaders"], header))

    cells =
      ~s(<td><a href="/?c=1_2">c</a></td><td><a href="/view/1">[Group] Frieren - 01 [1080p]</a></td>) <>
        ~s(<td><a href="magnet:?xt=urn:btih:#{String.duplicate("1", 40)}">m</a></td><td>1.0 GiB</td>)

    page = """
    <!doctype html><html><body><table class="torrent-list"><tbody>
    <tr class="h"><td colspan="6"><b>Yesterday 08:00</b></td></tr>
    <tr class="default">#{cells}</tr>
    </tbody></table></body></html>
    """

    assert dates(page) == [{"[Group] Frieren - 01 [1080p]", ~U[2026-11-25 08:00:00Z]}]
  end

  test "a date field outside the decided time bound reads nil, and the row stays" do
    nyaa!(with_fields([{"date", %{"selector" => "td:nth-child(5)"}}]))

    assert dates(nyaa_page(frieren(["Today 14:22 +0800", "Today 14:22 +08:00"]))) ==
             [
               {"[Group] Frieren - 01 [1080p]", nil},
               {"[Group] Frieren - 02 [1080p]", ~U[2026-11-26 06:22:00Z]}
             ]
  end

  test "a date header outside the decided time bound drops its rows that have no date" do
    header = %{"selector" => "td[colspan] > b", "optional" => true, "filters" => []}
    nyaa!(&put_in(&1, ["search", "rows", "dateheaders"], header))

    row = fn i, date ->
      ~s(<tr class="default"><td><a href="/?c=1_2">c</a></td>) <>
        ~s(<td><a href="/view/#{i}">[Group] Frieren - 0#{i} [1080p]</a></td>) <>
        ~s(<td><a href="magnet:?xt=urn:btih:#{String.duplicate("#{i}", 40)}">m</a></td>) <>
        ~s(<td>1.0 GiB</td><td>#{date}</td></tr>)
    end

    page = """
    <!doctype html><html><body><table class="torrent-list"><tbody>
    <tr class="h"><td colspan="6"><b>Today 14:22 +0800</b></td></tr>
    #{row.(1, "")}
    #{row.(3, "2026-11-20 08:00")}
    <tr class="h"><td colspan="6"><b>Today 14:22 +08:00</b></td></tr>
    #{row.(2, "")}
    </tbody></table></body></html>
    """

    assert dates(page) == [
             {"[Group] Frieren - 03 [1080p]", ~U[2026-11-20 08:00:00Z]},
             {"[Group] Frieren - 02 [1080p]", ~U[2026-11-26 06:22:00Z]}
           ]
  end
end
