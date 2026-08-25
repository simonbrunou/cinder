defmodule CinderWeb.BookDiscoveryLive do
  @moduledoc "Discovery and request page for one provider-backed book work."

  use CinderWeb, :live_view

  import CinderWeb.BookComponents
  import CinderWeb.LiveHelpers, only: [book_badge_state: 2, latest_status_by: 2]
  import CinderWeb.RequestHelpers

  alias Cinder.Books
  alias Cinder.Books.{Identity, Metadata, Work}
  alias Cinder.Catalog
  alias Cinder.LibraryKind
  alias Cinder.Requests

  @book_kinds LibraryKind.books()

  @impl true
  def mount(%{"provider" => raw_provider, "foreign_id" => foreign_id}, _session, socket) do
    case provider(raw_provider) do
      nil ->
        raise Ecto.NoResultsError, queryable: Work

      provider ->
        if connected?(socket) do
          Requests.subscribe()
          Books.subscribe_targets()
        end

        socket =
          assign(socket,
            provider: provider,
            foreign_id: foreign_id,
            resolution: nil,
            resolution_state: :loading,
            book_kinds: @book_kinds,
            book_profiles: Enum.flat_map(@book_kinds, &Catalog.list_profiles/1),
            book_states: %{},
            local_work_id: nil
          )

        {:ok, maybe_resolve(socket)}
    end
  end

  defp provider(name) do
    Enum.find_value(Metadata.providers(), fn module ->
      provider = module.provider()
      if to_string(provider) == name, do: provider
    end)
  end

  defp maybe_resolve(socket) do
    if connected?(socket), do: resolve(socket), else: socket
  end

  defp resolve(socket) do
    %{provider: provider, foreign_id: foreign_id} = socket.assigns

    start_async(socket, :resolve, fn ->
      provider
      |> Identity.reference_for(foreign_id)
      |> Identity.resolve()
    end)
  end

  @impl true
  def handle_event("retry", _params, socket) do
    {:noreply,
     socket
     |> assign(resolution: nil, resolution_state: :loading)
     |> resolve()}
  end

  def handle_event("request", %{"kind" => raw_kind}, socket) when is_binary(raw_kind) do
    request = request_attrs(kind(raw_kind))

    with %{resolution: resolution} when not is_nil(resolution) <- socket.assigns,
         %{media_kind: media_kind} <- request,
         profile_id when is_integer(profile_id) <-
           default_profile_id(socket.assigns.book_profiles, request),
         {:ok, profile} <- normalize_profile(Integer.to_string(profile_id), media_kind) do
      user = socket.assigns.current_scope.user
      title = resolution.work.title

      {:noreply,
       start_async(socket, {:request, media_kind, title}, fn ->
         with {:ok, work} <- Books.import_resolution(resolution) do
           Requests.create_request(user, %{
             target_type: "book",
             target_id: work.id,
             media_kind: media_kind,
             proposed_profile_id: profile.id,
             proposed_media_profile: :standard
           })
         end
       end)}
    else
      _invalid_or_unavailable -> {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({event, _request}, socket)
      when event in [:request_created, :request_approved, :request_denied, :request_deleted] do
    {:noreply, assign_book_state(socket)}
  end

  def handle_info(
        {:book_target_updated, %{work_id: work_id}},
        %{assigns: %{local_work_id: work_id}} = socket
      ) do
    {:noreply, assign_book_state(socket)}
  end

  def handle_info({:book_target_updated, _target}, socket), do: {:noreply, socket}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:resolve, {:ok, {:ok, resolution}}, socket) do
    {:noreply,
     socket
     |> assign(resolution: resolution, resolution_state: :ready)
     |> assign_book_state()}
  end

  def handle_async(:resolve, _failure, socket) do
    {:noreply, assign(socket, resolution: nil, resolution_state: :error)}
  end

  def handle_async({:request, _kind, title}, {:ok, result}, socket) do
    {:noreply,
     socket
     |> request_result(title, result)
     |> assign_book_state()}
  end

  def handle_async({:request, _kind, title}, {:exit, _reason}, socket) do
    {:noreply,
     put_flash(socket, :error, gettext("Couldn't request %{title}. Try again.", title: title))}
  end

  defp assign_book_state(%{assigns: %{resolution: nil}} = socket), do: socket

  defp assign_book_state(socket) do
    %{provider: provider, foreign_id: foreign_id, current_scope: %{user: user}} = socket.assigns
    key = {to_string(provider), foreign_id}
    work_id = Books.work_ids_by_reference([{provider, foreign_id}])[key]

    case work_id do
      nil ->
        assign(socket, book_states: %{}, local_work_id: nil)

      work_id ->
        request_states =
          user
          |> Requests.list_for_user()
          |> Enum.filter(&(&1.target_type == "book" and &1.target_id == work_id))
          |> latest_status_by(& &1.media_kind)

        target_states = Books.target_statuses([work_id])

        states =
          Map.new(@book_kinds, fn kind ->
            {kind, book_badge_state(request_states[kind], target_states[{work_id, kind}])}
          end)

        assign(socket, book_states: states, local_work_id: work_id)
    end
  end

  defp kind(raw), do: Enum.find(@book_kinds, &(to_string(&1) == raw))
  defp request_attrs(nil), do: nil

  defp request_attrs(kind),
    do: %{target_type: "book", media_kind: kind, proposed_profile_id: nil}

  defp profile_available?(profiles, kind),
    do: profiles_for(profiles, request_attrs(kind)) != []

  defp requestable?(state), do: state in [nil, :none, :denied]

  defp request_label(:ebook), do: gettext("Request eBook")
  defp request_label(:audiobook), do: gettext("Request audiobook")

  defp unavailable_label(:ebook), do: gettext("eBook requests aren't available yet.")
  defp unavailable_label(:audiobook), do: gettext("Audiobook requests aren't available yet.")

  defp configure_label(:ebook), do: gettext("Configure eBook profiles")
  defp configure_label(:audiobook), do: gettext("Configure audiobook profiles")

  defp editions(work, kind), do: Enum.filter(work.editions, &(&1.media_kind == kind))

  defp edition_count_label(:ebook, editions) do
    ngettext("1 eBook edition", "%{count} eBook editions", length(editions))
  end

  defp edition_count_label(:audiobook, editions) do
    ngettext("1 audiobook edition", "%{count} audiobook editions", length(editions))
  end

  defp languages(editions) do
    editions
    |> Enum.map(& &1.language)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.join(", ")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_count={@pending_count}
      holds_count={@holds_count}
    >
      <.link navigate={~p"/"} class="link link-hover mb-6 inline-flex items-center gap-1">
        <.icon name="hero-arrow-left" class="size-3.5" />{gettext("Discover")}
      </.link>

      <div :if={@resolution_state == :loading} id="book-resolution-loading">
        <.spinner label={gettext("Loading book…")} />
      </div>

      <div
        :if={@resolution_state == :error}
        id="book-resolution-error"
        class="card bg-base-200 shadow-sm"
      >
        <div class="card-body items-start">
          <h1 class="card-title">{gettext("We couldn’t load this book right now.")}</h1>
          <p class="text-sm text-base-content/70">
            {gettext("The metadata provider may be unavailable. Please try again.")}
          </p>
          <.button id="retry-book-resolution" phx-click="retry" variant="primary" size="sm">
            {gettext("Try again")}
          </.button>
        </div>
      </div>

      <%= if @resolution_state == :ready do %>
        <% work = @resolution.work %>
        <article id="book-work">
          <.header>
            {work.title}
            <span :if={work.first_published_on} class="font-normal text-base-content/70">
              ({work.first_published_on.year})
            </span>
            <:actions>
              <div class="flex flex-wrap gap-2">
                <.book_state_badge
                  :for={kind <- @book_kinds}
                  id={"book-state-#{kind}"}
                  kind={kind}
                  state={@book_states[kind] || :none}
                />
              </div>
            </:actions>
          </.header>

          <ul :if={work.contributors != []} class="flex flex-wrap gap-x-4 gap-y-1 text-sm">
            <li :for={contributor <- work.contributors}>
              {gettext("%{name}: %{role}", name: contributor.name, role: contributor.role)}
            </li>
          </ul>

          <p :if={work.overview} class="mt-4 max-w-prose text-sm leading-relaxed">
            {work.overview}
          </p>
          <p :if={is_nil(work.overview)} class="mt-4 text-sm text-base-content/50">
            {gettext("No description available.")}
          </p>

          <section :if={work.series != []} class="mt-6" aria-labelledby="book-series-heading">
            <h2 id="book-series-heading" class="font-semibold">{gettext("Series")}</h2>
            <ul class="mt-2 space-y-1 text-sm">
              <li :for={series <- work.series}>
                <%= if series.position do %>
                  {gettext("%{name} (position %{position})",
                    name: series.name,
                    position: series.position
                  )}
                <% else %>
                  {series.name}
                <% end %>
              </li>
            </ul>
          </section>

          <section class="mt-6" aria-labelledby="digital-editions-heading">
            <h2 id="digital-editions-heading" class="font-semibold">
              {gettext("Digital editions")}
            </h2>
            <ul class="mt-2 space-y-2 text-sm">
              <li :for={kind <- @book_kinds}>
                <% kind_editions = editions(work, kind) %>
                <span class="font-medium">{edition_count_label(kind, kind_editions)}</span>
                <span :if={languages(kind_editions) != ""} class="text-base-content/70">
                  {gettext("Languages: %{languages}", languages: languages(kind_editions))}
                </span>
              </li>
            </ul>
          </section>

          <section class="mt-8" aria-labelledby="book-requests-heading">
            <h2 id="book-requests-heading" class="font-semibold">{gettext("Request")}</h2>
            <div class="mt-3 flex flex-col gap-3 sm:flex-row">
              <div :for={kind <- @book_kinds} class="flex items-center gap-2">
                <.button
                  :if={
                    profile_available?(@book_profiles, kind) and
                      requestable?(@book_states[kind])
                  }
                  id={"request-#{kind}"}
                  phx-click="request"
                  phx-value-kind={kind}
                  variant="primary"
                  size="sm"
                  phx-disable-with={gettext("Requesting…")}
                >
                  {request_label(kind)}
                </.button>

                <%= if not profile_available?(@book_profiles, kind) do %>
                  <.link
                    :if={@current_scope.user.role == :admin}
                    navigate={~p"/settings/profiles"}
                    class="link link-primary text-sm"
                  >
                    {configure_label(kind)}
                  </.link>
                  <p
                    :if={@current_scope.user.role != :admin}
                    id={"#{kind}-unavailable"}
                    class="text-sm text-base-content/70"
                  >
                    {unavailable_label(kind)}
                  </p>
                <% end %>
              </div>
            </div>
          </section>
        </article>
      <% end %>
    </Layouts.app>
    """
  end
end
