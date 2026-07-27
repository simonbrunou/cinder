defmodule CinderWeb.IssueComponents do
  @moduledoc """
  Shared "Report an issue" markup + labels, used by the requester surfaces (`MyRequestsLive`,
  `MovieDiscoveryLive`) and the admin `IssuesLive` queue, so the category/status vocabulary has
  one gettext'd source. `use CinderWeb, :html` brings gettext and CoreComponents (`.button`).
  """
  use CinderWeb, :html

  alias Cinder.Issues.IssueReport

  @doc """
  A compact inline report form: a category select, an optional free-text detail, submit + cancel.
  The hidden `value` rides back as `_id` (not `id`, which would clash with the form element id) so
  the surface can resolve the target server-side (a request row id, or the page's tmdb_id) rather
  than trusting a client-supplied target.
  """
  attr :id, :string, required: true
  attr :value, :any, required: true
  attr :on_submit, :string, required: true
  attr :on_cancel, :string, required: true
  attr :class, :any, default: nil

  def report_form(assigns) do
    ~H"""
    <form id={@id} phx-submit={@on_submit} class={["flex flex-col gap-2", @class]}>
      <input type="hidden" name="_id" value={@value} />
      <label for={"#{@id}-category"} class="sr-only">{gettext("Issue category")}</label>
      <select id={"#{@id}-category"} name="category" class="select select-sm w-full">
        <option :for={category <- IssueReport.categories()} value={category}>
          {category_label(category)}
        </option>
      </select>
      <label for={"#{@id}-detail"} class="sr-only">{gettext("What's wrong? (optional)")}</label>
      <textarea
        id={"#{@id}-detail"}
        name="detail"
        rows="2"
        maxlength="1000"
        class="textarea textarea-sm w-full"
        placeholder={gettext("What's wrong? (optional)")}
      ></textarea>
      <div class="flex gap-2">
        <.button type="submit" variant="primary" size="sm" phx-disable-with={gettext("Sending…")}>
          {gettext("Submit report")}
        </.button>
        <.button type="button" variant="ghost" size="sm" phx-click={@on_cancel}>
          {gettext("Cancel")}
        </.button>
      </div>
    </form>
    """
  end

  @doc "A small status pill for a requester's own report."
  attr :status, :atom, required: true

  def report_status(assigns) do
    ~H"""
    <span class={["badge badge-sm gap-1", report_status_class(@status)]}>
      <.icon name="hero-flag" class="size-3.5" />{report_status_label(@status)}
    </span>
    """
  end

  @doc "Gettext label for a report category."
  def category_label(:wrong_content), do: gettext("Wrong movie or episode")
  def category_label(:audio), do: gettext("Audio problem")
  def category_label(:subtitles), do: gettext("Subtitle problem")
  def category_label(:playback), do: gettext("Playback / video problem")
  def category_label(:other), do: gettext("Something else")
  def category_label(other), do: to_string(other)

  @doc "Gettext label for a report status."
  def report_status_label(:open), do: gettext("Reported")
  def report_status_label(:resolved), do: gettext("Resolved")
  def report_status_label(:dismissed), do: gettext("Dismissed")

  defp report_status_class(:resolved), do: "badge-success"
  defp report_status_class(:dismissed), do: "badge-ghost"
  defp report_status_class(_open), do: "badge-warning"
end
