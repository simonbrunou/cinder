defmodule Cinder.Repo.Migrations.CreateBookAuthorPolicies do
  use Ecto.Migration

  def change do
    # A per-author bulk-monitoring policy (contract: "Automatic author monitoring"). No row means
    # "selected works" — the current B2-B4 behavior, where a work is monitored only because a
    # request approved it. `on_delete: :restrict` on `profile_id` (unlike `book_targets`'s own
    # `:nilify_all`): a policy with no profile to arm new targets with is meaningless, so deleting
    # an in-use profile must fail closed rather than leave a policy that can never confirm.
    create table(:book_author_policies) do
      add :author_id, references(:book_authors, on_delete: :delete_all), null: false

      add :policy, :string,
        null: false,
        check: %{
          name: "book_author_policies_policy_valid",
          expr: "policy IN ('future', 'all')"
        }

      add :profile_id, references(:media_profiles, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:book_author_policies, [:author_id])
    create index(:book_author_policies, [:profile_id])
  end
end
