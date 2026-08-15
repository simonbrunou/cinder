defmodule CinderWeb.ProfilesLive do
  @moduledoc "Admin management for named movie and TV media profiles."
  use CinderWeb, :live_view

  alias Cinder.Catalog
  alias Cinder.Catalog.Profile

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(editing: nil, confirming_delete: nil)
     |> reload()
     |> assign_form(%Profile{}, %{"kind" => "movies", "handling" => "standard"})}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply,
     socket
     |> assign(editing: nil, confirming_delete: nil)
     |> assign_form(%Profile{}, %{"kind" => "movies", "handling" => "standard"})}
  end

  def handle_event("edit", %{"id" => raw}, socket) do
    case profile(socket, raw) do
      nil ->
        {:noreply, socket}

      profile ->
        {:noreply,
         socket |> assign(editing: profile, confirming_delete: nil) |> assign_form(profile)}
    end
  end

  def handle_event("validate", %{"profile" => params}, socket) when is_map(params) do
    profile = socket.assigns.editing || %Profile{}
    changeset = Profile.changeset(profile, params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, form: to_form(changeset, as: :profile))}
  end

  def handle_event("save", %{"profile" => params}, socket) when is_map(params) do
    result =
      case socket.assigns.editing do
        nil -> Catalog.create_profile(params)
        profile -> Catalog.update_profile(profile, params)
      end

    case result do
      {:ok, _profile} ->
        {:noreply,
         socket
         |> assign(editing: nil)
         |> reload()
         |> assign_form(%Profile{}, %{"kind" => "movies", "handling" => "standard"})
         |> put_flash(:info, gettext("Media profile saved."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :profile))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't save the media profile."))}
    end
  end

  def handle_event("ask_delete", %{"id" => raw}, socket) do
    case profile(socket, raw) do
      nil -> {:noreply, socket}
      profile -> {:noreply, assign(socket, confirming_delete: profile)}
    end
  end

  def handle_event("cancel_delete", _params, socket),
    do: {:noreply, assign(socket, confirming_delete: nil)}

  def handle_event("delete", %{"id" => raw}, socket) do
    case profile(socket, raw) do
      nil ->
        {:noreply, assign(socket, confirming_delete: nil)}

      profile ->
        case Catalog.delete_profile(profile) do
          {:ok, _profile} ->
            {:noreply,
             socket
             |> assign(confirming_delete: nil)
             |> reload()
             |> put_flash(:info, gettext("Media profile deleted."))}

          {:error, reason} when reason in [:in_use, :last_profile] ->
            {:noreply,
             socket
             |> assign(confirming_delete: nil)
             |> put_flash(:error, delete_error(reason))}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(confirming_delete: nil)
             |> put_flash(:error, gettext("Couldn't delete the media profile."))}
        end
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp reload(socket), do: assign(socket, profiles: Catalog.list_profiles())

  defp assign_form(socket, profile, attrs \\ %{}) do
    assign(socket, form: to_form(Profile.changeset(profile, attrs), as: :profile))
  end

  defp profile(socket, raw) when is_binary(raw) do
    with {id, ""} <- Integer.parse(raw) do
      Enum.find(socket.assigns.profiles, &(&1.id == id))
    else
      _ -> nil
    end
  end

  defp profile(_socket, _raw), do: nil

  defp delete_error(:in_use),
    do: gettext("That profile is assigned to a title or request and can't be deleted.")

  defp delete_error(:last_profile),
    do: gettext("Each media kind must keep at least one profile.")

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
      <.link navigate={~p"/settings"} class="link link-hover mb-6 inline-flex items-center gap-1">
        <.icon name="hero-arrow-left" class="size-3.5" />{gettext("Settings")}
      </.link>

      <.header>
        {gettext("Media profiles")}
        <:subtitle>
          {gettext("Name movie and TV destinations while reusing Standard or Anime handling.")}
        </:subtitle>
        <:actions>
          <.button type="button" variant="neutral" size="sm" phx-click="new">
            {gettext("New profile")}
          </.button>
        </:actions>
      </.header>

      <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(18rem,24rem)]">
        <ul id="profiles" class="space-y-3">
          <li
            :for={profile <- @profiles}
            id={"profile-#{profile.id}"}
            class="card bg-base-200 shadow-sm"
          >
            <div class="card-body gap-2 p-4">
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <h2 class="card-title text-base">{profile.name}</h2>
                  <p class="text-sm text-base-content/70">
                    {profile_kind_label(profile.kind)} · {handling_label(profile.handling)}
                  </p>
                  <p :if={profile.library_path} class="mt-1 break-all text-sm">
                    {profile.library_path}
                  </p>
                  <p :if={is_nil(profile.library_path)} class="mt-1 text-sm text-base-content/60">
                    {gettext("Uses the existing library root")}
                  </p>
                </div>
                <div class="flex gap-2">
                  <.button
                    type="button"
                    variant="ghost"
                    size="sm"
                    phx-click="edit"
                    phx-value-id={profile.id}
                  >
                    {gettext("Edit")}
                  </.button>
                  <.button
                    type="button"
                    variant="ghost"
                    size="sm"
                    class="text-error"
                    phx-click="ask_delete"
                    phx-value-id={profile.id}
                  >
                    {gettext("Delete")}
                  </.button>
                </div>
              </div>

              <.confirm_action
                :if={@confirming_delete && @confirming_delete.id == profile.id}
                id={"confirm-delete-profile-#{profile.id}"}
                on_confirm="delete"
                on_cancel="cancel_delete"
                value={profile.id}
                confirm_label={gettext("Delete profile")}
              >
                <:caveat>
                  {gettext(
                    "Delete %{name}? This works only when nothing references it and another profile of this kind remains.",
                    name: profile.name
                  )}
                </:caveat>
              </.confirm_action>
            </div>
          </li>
        </ul>

        <section class="card h-fit bg-base-200 shadow-sm" aria-labelledby="profile-form-heading">
          <div class="card-body p-5">
            <h2 id="profile-form-heading" class="card-title text-lg">
              {if @editing, do: gettext("Edit profile"), else: gettext("New profile")}
            </h2>
            <.form
              for={@form}
              id="profile-form"
              phx-change="validate"
              phx-submit="save"
              class="space-y-3"
            >
              <.input field={@form[:name]} type="text" label={gettext("Name")} />
              <.input
                field={@form[:kind]}
                type="select"
                label={gettext("Media kind")}
                options={[{gettext("Movies"), "movies"}, {gettext("TV"), "tv"}]}
              />
              <.input
                field={@form[:handling]}
                type="select"
                label={gettext("Handling")}
                options={[{gettext("Standard"), "standard"}, {gettext("Anime"), "anime"}]}
              />
              <.input
                field={@form[:library_path]}
                type="text"
                label={gettext("Library path")}
                placeholder={gettext("Use existing library root")}
              />
              <.button type="submit" variant="primary" phx-disable-with={gettext("Saving…")}>
                {gettext("Save profile")}
              </.button>
            </.form>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp profile_kind_label(:movies), do: gettext("Movies")
  defp profile_kind_label(:tv), do: gettext("TV")
  defp handling_label(:anime), do: gettext("Anime")
  defp handling_label(_standard), do: gettext("Standard")
end
