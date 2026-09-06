defmodule CinderWeb.LibraryAdoptionComponents do
  @moduledoc """
  Presentation pieces of the /library/adopt page split out of `CinderWeb.LibraryAdoptionLive` to
  keep it under the project's 1500-line file-health gate (`Cinder.CodeHealthTest`) — the same
  reason `Cinder.Catalog` split into `Discovery`/`Grabs`/`SeriesCatalog`. `migration_title/1`,
  `file_name/1`, and `migration_pager/1` are used by both `migration_decision_section/1` here
  and the LiveView's own remaining sections (auto-matched, blocked, already-managed); the
  LiveView imports them back rather than duplicating.
  """

  use CinderWeb, :html

  alias Cinder.Library.Adoption

  def migration_title(candidate) do
    case Map.get(candidate, :year) do
      year when is_integer(year) -> "#{candidate.title} (#{year})"
      _year -> candidate.title
    end
  end

  def file_name(path) when is_binary(path), do: Path.basename(path)
  def file_name(_path), do: gettext("No file")

  # Mirrors CinderWeb.LibraryAdoptionLive's own @page_size (50) — migration_pager/1 is the only
  # caller, and this is the only place total_pages/1 is needed.
  @page_size 50

  defp total_pages(count) when count <= 0, do: 1
  defp total_pages(count), do: ceil(count / @page_size)

  attr :bucket, :atom, required: true
  attr :page, :integer, required: true
  attr :count, :integer, required: true
  attr :label, :string, required: true

  def migration_pager(assigns) do
    assigns = assign(assigns, :total, total_pages(assigns.count))

    ~H"""
    <nav
      :if={@total > 1}
      class="mt-3 flex items-center justify-center gap-3"
      aria-label={gettext("%{label} pages", label: @label)}
    >
      <.button
        type="button"
        variant="neutral"
        size="sm"
        phx-click="page"
        phx-value-bucket={@bucket}
        phx-value-dir="prev"
        disabled={@page <= 1}
        aria-label={gettext("Previous page of %{label}", label: @label)}
      >
        {gettext("Previous")}
      </.button>
      <span class="text-sm text-base-content/70">
        {gettext("Page %{page} of %{total}", page: @page, total: @total)}
      </span>
      <.button
        type="button"
        variant="neutral"
        size="sm"
        phx-click="page"
        phx-value-bucket={@bucket}
        phx-value-dir="next"
        disabled={@page >= @total}
        aria-label={gettext("Next page of %{label}", label: @label)}
      >
        {gettext("Next")}
      </.button>
    </nav>
    """
  end

  # Whether the Needs-decision bucket contains at least one candidate of `kind` — gates which
  # bulk "Apply ... to all undecided" button/copy renders, since Fold/Part only ever mean
  # anything for an episode candidate and Preferred format/All formats only for a book one
  # (`decision_choice_matches_kind?/2`, still in the LiveView, already refuses the mismatched
  # write; this just keeps the UI from offering a control that would silently do nothing).
  defp needs_decision_kind?(candidates, kind), do: Enum.any?(candidates, &(&1.kind == kind))

  attr :counts, :map, required: true
  attr :migration_buckets, :map, required: true
  attr :decisions, :map, required: true
  attr :streams, :map, required: true
  attr :pages, :map, required: true

  def migration_decision_section(assigns) do
    ~H"""
    <section :if={@counts.ambiguous > 0} aria-labelledby="migration-decision-heading">
      <div class="mb-3 flex flex-wrap items-center justify-between gap-3">
        <h2 id="migration-decision-heading" class="text-xl font-semibold">
          {gettext("Needs decision")} ({@counts.ambiguous})
        </h2>
        <div class="flex flex-wrap items-center gap-3">
          <span
            id="migration-decisions-pending"
            class="text-sm text-base-content/70"
            aria-live="polite"
          >
            {ngettext(
              "%{count} decision pending",
              "%{count} decisions pending",
              Adoption.undecided_count(@migration_buckets.needs_decision, @decisions)
            )}
          </span>
          <.button
            :if={needs_decision_kind?(@migration_buckets.needs_decision, :episode)}
            type="button"
            variant="neutral"
            size="sm"
            phx-click="apply_all"
            phx-value-choice="fold"
            aria-label={gettext("Apply Fold to all undecided items")}
          >
            {gettext("Apply Fold to all undecided")}
          </.button>
          <.button
            :if={needs_decision_kind?(@migration_buckets.needs_decision, :episode)}
            type="button"
            variant="neutral"
            size="sm"
            phx-click="apply_all"
            phx-value-choice="part"
            aria-label={gettext("Apply Part to all undecided items")}
          >
            {gettext("Apply Part to all undecided")}
          </.button>
          <.button
            :if={needs_decision_kind?(@migration_buckets.needs_decision, :book)}
            type="button"
            variant="neutral"
            size="sm"
            phx-click="apply_all"
            phx-value-choice="preferred"
            aria-label={gettext("Apply Preferred format to all undecided items")}
          >
            {gettext("Apply Preferred format to all undecided")}
          </.button>
          <.button
            :if={needs_decision_kind?(@migration_buckets.needs_decision, :book)}
            type="button"
            variant="neutral"
            size="sm"
            phx-click="apply_all"
            phx-value-choice="all_formats"
            aria-label={gettext("Apply All formats to all undecided items")}
          >
            {gettext("Apply All formats to all undecided")}
          </.button>
        </div>
      </div>
      <p
        :if={needs_decision_kind?(@migration_buckets.needs_decision, :episode)}
        class="mb-3 text-sm text-base-content/70"
      >
        {gettext(
          "Sonarr split several TVDB episodes into files that map to one TMDB episode. Choose how to treat each extra file."
        )}
      </p>
      <p
        :if={needs_decision_kind?(@migration_buckets.needs_decision, :book)}
        class="mb-3 text-sm text-base-content/70"
      >
        {gettext(
          "This book has multiple accepted formats. Choose whether to keep only the preferred one or adopt them all."
        )}
      </p>
      <div id="migration-decision-candidates" phx-update="stream" class="space-y-3">
        <article
          :for={{dom_id, candidate} <- @streams.ambiguous_candidates}
          id={dom_id}
          class="card border border-warning/40 bg-base-100"
        >
          <div class="card-body gap-3 p-4">
            <div>
              <p class="font-semibold">{migration_title(candidate)}</p>
              <p class="font-mono text-sm text-base-content/70">
                {gettext("Primary: %{file}", file: file_name(candidate.primary_file.path))}
              </p>
              <p
                :for={file <- candidate.extra_files}
                class="font-mono text-sm text-base-content/70"
              >
                {gettext("Extra: %{file}", file: file_name(file.path))}
              </p>
            </div>
            <fieldset class="space-y-2">
              <legend class="sr-only">
                {gettext("Migration choice for %{title}", title: migration_title(candidate))}
              </legend>
              <label
                :if={candidate.kind == :episode}
                class="flex min-h-11 cursor-pointer items-start gap-3 rounded-lg border border-base-300 px-3 py-2"
              >
                <input
                  type="radio"
                  name={"migration-choice-#{candidate.id}"}
                  value="fold"
                  checked={Map.get(@decisions, candidate.id) == "fold"}
                  phx-click="set_decision"
                  phx-value-id={candidate.id}
                  phx-value-choice="fold"
                  class="radio radio-primary mt-0.5"
                />
                <span>
                  <span class="block font-medium">{gettext("Fold")}</span>
                  <span class="text-sm text-base-content/70">
                    {gettext(
                      "Adopt the authoritative primary, save both provider coordinates, and leave the extra file unmanaged."
                    )}
                  </span>
                </span>
              </label>
              <label
                :if={candidate.kind == :episode}
                class="flex min-h-11 cursor-pointer items-start gap-3 rounded-lg border border-base-300 px-3 py-2"
              >
                <input
                  type="radio"
                  name={"migration-choice-#{candidate.id}"}
                  value="part"
                  checked={Map.get(@decisions, candidate.id) == "part"}
                  phx-click="set_decision"
                  phx-value-id={candidate.id}
                  phx-value-choice="part"
                  class="radio radio-primary mt-0.5"
                />
                <span>
                  <span class="block font-medium">{gettext("Part")}</span>
                  <span class="text-sm text-base-content/70">
                    {gettext("Adopt the extra file as an explicit part of the primary episode.")}
                  </span>
                </span>
              </label>
              <label
                :if={candidate.kind == :book and candidate.reason != :multi_track}
                class="flex min-h-11 cursor-pointer items-start gap-3 rounded-lg border border-base-300 px-3 py-2"
              >
                <input
                  type="radio"
                  name={"migration-choice-#{candidate.id}"}
                  value="preferred"
                  checked={Map.get(@decisions, candidate.id) == "preferred"}
                  phx-click="set_decision"
                  phx-value-id={candidate.id}
                  phx-value-choice="preferred"
                  class="radio radio-primary mt-0.5"
                />
                <span>
                  <span class="block font-medium">{gettext("Preferred format")}</span>
                  <span class="text-sm text-base-content/70">
                    {gettext(
                      "Adopt only the preferred format (EPUB, else AZW3, else MOBI). The other files are left untouched on disk."
                    )}
                  </span>
                </span>
              </label>
              <label
                :if={candidate.kind == :book and candidate.reason != :multi_track}
                class="flex min-h-11 cursor-pointer items-start gap-3 rounded-lg border border-base-300 px-3 py-2"
              >
                <input
                  type="radio"
                  name={"migration-choice-#{candidate.id}"}
                  value="all_formats"
                  checked={Map.get(@decisions, candidate.id) == "all_formats"}
                  phx-click="set_decision"
                  phx-value-id={candidate.id}
                  phx-value-choice="all_formats"
                  class="radio radio-primary mt-0.5"
                />
                <span>
                  <span class="block font-medium">{gettext("All formats")}</span>
                  <span class="text-sm text-base-content/70">
                    {gettext("Adopt every accepted-format file for this work.")}
                  </span>
                </span>
              </label>
              <label
                :if={candidate.kind == :book and candidate.reason == :multi_track}
                class="flex min-h-11 cursor-pointer items-start gap-3 rounded-lg border border-base-300 px-3 py-2"
              >
                <input
                  type="radio"
                  name={"migration-choice-#{candidate.id}"}
                  value="all_formats"
                  checked={Map.get(@decisions, candidate.id) in ["preferred", "all_formats"]}
                  phx-click="set_decision"
                  phx-value-id={candidate.id}
                  phx-value-choice="all_formats"
                  class="radio radio-primary mt-0.5"
                />
                <span>
                  <span class="block font-medium">{gettext("Adopt all tracks")}</span>
                  <span class="text-sm text-base-content/70">
                    {gettext(
                      "These files are sequential tracks of one audiobook, not alternative formats. Every track is adopted together."
                    )}
                  </span>
                </span>
              </label>
            </fieldset>
          </div>
        </article>
      </div>
      <.migration_pager
        bucket={:needs_decision}
        page={@pages.needs_decision}
        count={@counts.ambiguous}
        label={gettext("Needs decision")}
      />
    </section>
    """
  end
end
