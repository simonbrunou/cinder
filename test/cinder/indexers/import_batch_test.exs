defmodule Cinder.Indexers.ImportBatchTest do
  # `Cinder.Indexers.import_batch/2`, the Prowlarr import's one write (#1673): its checks inside
  # the transaction and the codes of an insert the database or the checks refuse.
  use Cinder.DataCase, async: true

  import Ecto.Query

  alias Cinder.Accounts.User
  alias Cinder.Audit.AdminAudit
  alias Cinder.Indexers
  alias Cinder.Indexers.ConfiguredIndexer

  defp entry(prowlarr_id, name, extra \\ %{}) do
    %{
      prowlarr_id: prowlarr_id,
      attrs:
        Map.merge(
          %{
            "name" => name,
            "type" => :newznab,
            "base_url" => "https://n#{prowlarr_id}.example",
            "api_path" => "/api"
          },
          extra
        ),
      secrets: %{"api_key" => "key-#{prowlarr_id}"}
    }
  end

  defp configured, do: Repo.all(from c in ConfiguredIndexer, order_by: c.id)

  defp audits, do: Repo.all(from a in AdminAudit, where: a.action == "import_prowlarr_indexers")

  test "creates every entry linked, in the order given, with one audit row" do
    assert {:ok, [b, a]} = Indexers.import_batch(nil, [entry(9, "B"), entry(4, "A")])

    assert for(c <- configured(), do: {c.id, c.prowlarr_indexer_id, c.name}) ==
             [{b.id, 9, "B"}, {a.id, 4, "A"}]

    assert Indexers.prowlarr_links() == [{b.id, 9}, {a.id, 4}]
    assert {:ok, %{secrets: %{"api_key" => "key-9"}}} = Indexers.fetch_with_secrets(b.id)
    assert [%AdminAudit{detail: %{"count" => 2, "prowlarr_indexer_ids" => [9, 4]}}] = audits()
  end

  test "an entry already linked, or whose trimmed name is held, refuses the batch before any insert" do
    {:ok, _} = Indexers.import_batch(nil, [entry(1, "Held")])

    assert {:error, {:rows, errors}} =
             Indexers.import_batch(nil, [entry(2, "Free"), entry(1, "Other"), entry(3, " Held ")])

    assert errors == %{1 => [:already_imported], 3 => [:name_taken]}
    assert length(configured()) == 1
    assert length(audits()) == 1
  end

  test "an insert the unique indexes refuse rolls the batch back with its code" do
    assert {:error, {:rows, %{5 => [:link_conflict]}}} =
             Indexers.import_batch(nil, [entry(5, "One"), entry(5, "Two")])

    assert {:error, {:rows, %{7 => [:name_conflict]}}} =
             Indexers.import_batch(nil, [entry(6, "Same"), entry(7, "Same")])

    assert configured() == []
    assert audits() == []
  end

  test "an insert the checks refuse rolls the batch back with each field and validation" do
    assert {:error, {:rows, %{2 => errors}}} =
             Indexers.import_batch(nil, [
               entry(1, "Fine"),
               entry(2, "Bad", %{
                 "base_url" => "https://u:p@x.example",
                 "api_path" => "//evil/api"
               })
             ])

    assert Enum.sort(errors) == [
             {:api_path, :api_path_authority},
             {:base_url, :base_url_userinfo}
           ]

    assert configured() == []
  end

  test "a refused audit row rolls the batch back" do
    assert {:error, %Ecto.Changeset{data: %AdminAudit{}}} =
             Indexers.import_batch(%User{id: "not-an-id"}, [entry(1, "One")])

    assert configured() == []
  end
end
