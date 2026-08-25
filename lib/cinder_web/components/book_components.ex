defmodule CinderWeb.BookComponents do
  @moduledoc "Shared book discovery cards and per-format request state."

  use CinderWeb, :html

  alias Cinder.LibraryKind

  attr :id, :string, required: true
  attr :results, :list, required: true
  attr :states, :map, required: true

  # ponytail: text-only cards cap scan density; add provider cover fields and adapter support
  # when households measurably struggle to scan the grid.
  def book_cards(assigns) do
    ~H"""
    <div id={@id} class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
      <article
        :for={book <- @results}
        class="card bg-base-200 shadow-sm"
      >
        <div class="card-body gap-3 p-4">
          <h3 class="card-title text-base leading-tight">
            <.link
              navigate={~p"/book/#{book.provider}/#{book.foreign_id}"}
              class="link link-hover"
              aria-label={gettext("View %{title}", title: book.title)}
            >
              {book.title}
            </.link>
          </h3>

          <p :if={book.contributors != []} class="text-sm text-base-content/70">
            {Enum.map_join(book.contributors, ", ", & &1.name)}
          </p>

          <div class="flex flex-wrap gap-x-3 gap-y-1 text-xs text-base-content/70">
            <span :if={book.first_published_year}>
              {gettext("First published %{year}", year: book.first_published_year)}
            </span>
            <span>{edition_count(book.edition_count)}</span>
          </div>

          <div class="flex flex-wrap gap-2">
            <.book_state_badge
              :for={kind <- LibraryKind.books()}
              id={"book-state-#{book.provider}-#{book.foreign_id}-#{kind}"}
              kind={kind}
              state={state_for(@states, book, kind)}
            />
          </div>
        </div>
      </article>
    </div>
    """
  end

  attr :id, :string, default: nil
  attr :kind, :atom, required: true, values: [:ebook, :audiobook]
  attr :state, :atom, required: true

  def book_state_badge(assigns) do
    ~H"""
    <span
      :if={@state != :none}
      id={@id}
      class="inline-flex flex-wrap items-center gap-1.5 text-xs font-medium"
    >
      {kind_label(@kind)}
      <.status_badge kind={:request} status={@state} />
    </span>
    """
  end

  defp kind_label(:ebook), do: gettext("eBook")
  defp kind_label(:audiobook), do: gettext("Audiobook")

  defp state_for(states, book, kind),
    do: Map.get(states, {to_string(book.provider), book.foreign_id, kind}, :none)

  defp edition_count(count),
    do: ngettext("1 digital edition", "%{count} digital editions", count)
end
