defmodule CinderWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use CinderWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_scope, :map, default: nil, doc: "the current scope (may carry a nil user)"
  attr :current_path, :string, default: nil, doc: "the active request path, for nav highlighting"
  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :admin?, match?(%{user: %{role: :admin}}, assigns.current_scope))
    assigns = assign(assigns, :signed_in?, match?(%{user: %{}}, assigns.current_scope))

    ~H"""
    <a
      href="#main"
      class="sr-only focus:not-sr-only focus:absolute focus:z-50 focus:m-2 focus:btn focus:btn-primary"
    >
      {gettext("Skip to content")}
    </a>

    <div :if={@signed_in?} class="drawer lg:drawer-open">
      <input
        id="nav-drawer"
        type="checkbox"
        class="drawer-toggle"
        aria-label={gettext("Toggle navigation menu")}
      />

      <div class="drawer-content flex min-h-screen flex-col">
        <header class="navbar border-b border-base-300/60 bg-base-100 lg:hidden">
          <label for="nav-drawer" class="btn btn-ghost btn-square" aria-label={gettext("Open menu")}>
            <.icon name="hero-bars-3" class="size-6" />
          </label>
          <span class="font-display text-lg font-bold tracking-wide">
            CIN<span class="text-primary">DER</span>
          </span>
        </header>

        <main id="main" class="mx-auto w-full max-w-6xl flex-1 px-4 py-8 sm:px-6 lg:px-8">
          {render_slot(@inner_block)}
        </main>
      </div>

      <div class="drawer-side z-20">
        <label for="nav-drawer" aria-label={gettext("Close menu")} class="drawer-overlay"></label>
        <aside class="flex min-h-screen w-64 flex-col gap-2 border-r border-base-300/60 bg-base-200 p-4">
          <a
            href={if @admin?, do: ~p"/dashboard", else: ~p"/"}
            class="mb-2 flex items-center gap-2 px-2"
          >
            <span class="font-display text-xl font-bold tracking-wide">
              CIN<span class="text-primary">DER</span>
            </span>
          </a>

          <ul class="menu w-full gap-1 px-0">
            <li class="menu-title text-base-content/70">{gettext("Everyone")}</li>
            <.nav_item
              navigate={~p"/"}
              label={gettext("Discover")}
              icon="hero-magnifying-glass"
              current_path={@current_path}
            />
            <.nav_item
              navigate={~p"/my-requests"}
              label={gettext("My requests")}
              icon="hero-bookmark"
              current_path={@current_path}
            />

            <%= if @admin? do %>
              <li class="menu-title mt-2 text-base-content/70">{gettext("Admin")}</li>
              <.nav_item
                navigate={~p"/dashboard"}
                label={gettext("Dashboard")}
                icon="hero-squares-2x2"
                current_path={@current_path}
              />
              <.nav_item
                navigate={~p"/requests"}
                label={gettext("Requests")}
                icon="hero-inbox-arrow-down"
                current_path={@current_path}
              />
              <.nav_item
                navigate={~p"/library"}
                label={gettext("Library")}
                icon="hero-rectangle-stack"
                current_path={@current_path}
              />
              <.nav_item
                navigate={~p"/activity"}
                label={gettext("Activity")}
                icon="hero-bolt"
                current_path={@current_path}
              />
              <.nav_item
                navigate={~p"/calendar"}
                label={gettext("Calendar")}
                icon="hero-calendar"
                current_path={@current_path}
              />
              <.nav_item
                navigate={~p"/settings"}
                label={gettext("Settings")}
                icon="hero-cog-6-tooth"
                current_path={@current_path}
              />
              <.nav_item
                navigate={~p"/users"}
                label={gettext("Users")}
                icon="hero-users"
                current_path={@current_path}
              />
            <% end %>
          </ul>

          <div class="mt-auto flex flex-col gap-3 border-t border-base-300/60 pt-3">
            <div class="flex items-center justify-between gap-2">
              <.theme_toggle />
              <.locale_switcher />
            </div>
            <div class="px-2 text-xs text-base-content/70 truncate">
              {@current_scope.user.email}
            </div>
            <ul class="menu w-full gap-1 px-0">
              <.nav_item
                navigate={~p"/users/settings"}
                label={gettext("Account")}
                icon="hero-user-circle"
                current_path={@current_path}
              />
              <li>
                <.link href={~p"/users/log-out"} method="delete" class="flex items-center gap-3">
                  <.icon name="hero-arrow-right-start-on-rectangle" class="size-5" /> {gettext(
                    "Log out"
                  )}
                </.link>
              </li>
            </ul>
          </div>
        </aside>
      </div>
    </div>

    <main
      :if={!@signed_in?}
      id="main"
      class="mx-auto flex min-h-screen max-w-md flex-col justify-center px-4 py-10"
    >
      <div class="mb-6 text-center font-display text-2xl font-bold tracking-wide">
        CIN<span class="text-primary">DER</span>
      </div>
      {render_slot(@inner_block)}
      <div class="mt-6 flex justify-center">
        <.locale_switcher />
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  attr :navigate, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :current_path, :string, default: nil

  defp nav_item(assigns) do
    active =
      assigns.current_path == assigns.navigate or
        (assigns.navigate != "/" and is_binary(assigns.current_path) and
           String.starts_with?(assigns.current_path, assigns.navigate))

    assigns = assign(assigns, :active, active)

    ~H"""
    <li>
      <.link
        navigate={@navigate}
        aria-current={@active && "page"}
        class={["flex items-center gap-3", @active && "menu-active font-medium text-primary"]}
      >
        <.icon name={@icon} class="size-5 opacity-80" />
        {@label}
      </.link>
    </li>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Language switcher. Plain links (no JS) so it also works on logged-out pages; the
  active locale is read from Gettext in the rendering process (set by the Locale
  plug/on_mount), so no assign needs threading through every page.
  """
  def locale_switcher(assigns) do
    assigns = assign(assigns, :current, Gettext.get_locale(CinderWeb.Gettext))

    ~H"""
    <div class="join" role="group" aria-label={gettext("Language")}>
      <.link
        :for={loc <- CinderWeb.Locale.locales()}
        href={~p"/locale/#{loc}"}
        aria-current={loc == @current && "true"}
        class={["btn btn-xs join-item uppercase", loc == @current && "btn-active btn-primary"]}
      >
        {loc}
      </.link>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      role="radiogroup"
      aria-label={gettext("Theme")}
      class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full"
    >
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 [[data-theme=light]_&]:brightness-100 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        type="button"
        role="radio"
        aria-checked="true"
        aria-label={gettext("Use system theme")}
        class="flex items-center justify-center min-h-11 w-1/3 cursor-pointer rounded-full focus-visible:outline-2 focus-visible:outline-primary"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        type="button"
        role="radio"
        aria-checked="false"
        aria-label={gettext("Use light theme")}
        class="flex items-center justify-center min-h-11 w-1/3 cursor-pointer rounded-full focus-visible:outline-2 focus-visible:outline-primary"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        type="button"
        role="radio"
        aria-checked="false"
        aria-label={gettext("Use dark theme")}
        class="flex items-center justify-center min-h-11 w-1/3 cursor-pointer rounded-full focus-visible:outline-2 focus-visible:outline-primary"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
