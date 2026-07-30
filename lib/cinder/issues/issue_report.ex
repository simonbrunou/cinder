defmodule Cinder.Issues.IssueReport do
  @moduledoc """
  A requester's post-delivery problem report against an available title (Seerr parity). Kept
  entirely separate from `Cinder.Requests.Request` — the approval gate and request model are
  untouched. Polymorphic target mirrors requests (a movie `tmdb_id`, or a series `tmdb_id` +
  `season_number`); `title` is a snapshot so the admin queue renders without a catalog join.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @categories [:wrong_content, :audio, :subtitles, :playback, :other]
  @statuses [:open, :resolved, :dismissed]
  @target_types ["movie", "season"]
  @max_detail 1000

  def categories, do: @categories

  schema "issue_reports" do
    field :target_type, :string
    field :target_id, :integer
    field :season_number, :integer
    field :title, :string
    field :category, Ecto.Enum, values: @categories
    field :detail, :string
    field :status, Ecto.Enum, values: @statuses, default: :open
    belongs_to :user, Cinder.Accounts.User
    belongs_to :resolver, Cinder.Accounts.User
    timestamps()
  end

  def create_changeset(report, attrs) do
    report
    |> cast(attrs, [
      :user_id,
      :target_type,
      :target_id,
      :season_number,
      :title,
      :category,
      :detail,
      :status
    ])
    |> validate_required([:user_id, :target_type, :target_id, :category, :status])
    |> validate_inclusion(:target_type, @target_types)
    |> validate_length(:detail, max: @max_detail)
  end
end
