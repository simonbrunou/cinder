defmodule CinderWeb.UserLive.Login do
  use CinderWeb, :live_view

  alias Cinder.Accounts.JellyfinAuth
  alias Cinder.Accounts.OIDC
  alias Cinder.Accounts.PlexAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="text-center">
          <.header>
            <p>{gettext("Log in")}</p>
            <:subtitle>
              <%= if @current_scope do %>
                {gettext("You need to log in again to perform sensitive actions on your account.")}
              <% else %>
                {gettext("Don't have an account?")} <.link
                  navigate={~p"/users/register"}
                  class="font-semibold text-primary hover:underline focus-visible:underline"
                  phx-no-format
                >{gettext("Sign up")}</.link> {gettext("for an account now.")}
              <% end %>
            </:subtitle>
          </.header>
        </div>

        <.form
          :let={f}
          for={@form}
          id="login_form_password"
          action={~p"/users/log-in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
            type="email"
            label={gettext("Email")}
            autocomplete="username"
            spellcheck="false"
            required
          />
          <.input
            field={@form[:password]}
            type="password"
            label={gettext("Password")}
            autocomplete="current-password"
            spellcheck="false"
          />
          <.button class="w-full" name={@form[:remember_me].name} value="true">
            {gettext("Log in and stay logged in")}<.icon name="hero-arrow-right" class="size-3.5" />
          </.button>
          <.button variant="ghost" class="w-full mt-2">
            {gettext("Log in only this time")}
          </.button>
        </.form>

        <div class="divider">{gettext("or")}</div>

        <%!-- The PasskeySignIn hook fetches the options, asks the browser for the passkey, fills
        the hidden fields and submits the form. phx-update="ignore" keeps a re-render from
        clearing what it filled. --%>
        <.form
          for={@passkey_form}
          id="passkey_login_form"
          action={~p"/users/log-in/passkey"}
          method="post"
          phx-hook="PasskeySignIn"
          data-options-url={~p"/users/log-in/passkey/options"}
        >
          <div id="passkey_login_fields" phx-update="ignore">
            <input
              :for={field <- ~w(id authenticatorData clientDataJSON signature userHandle)}
              type="hidden"
              name={"passkey[#{field}]"}
              data-passkey-field={field}
            />
          </div>
          <label :if={!@current_scope} class="label cursor-pointer justify-start gap-2">
            <input type="checkbox" name="passkey[remember_me]" value="true" class="checkbox" />
            <span class="label-text">{gettext("Stay logged in")}</span>
          </label>
          <.button
            type="button"
            id="passkey_login_button"
            variant="neutral"
            class="w-full mt-2"
            data-passkey-start
          >
            <.icon name="hero-finger-print" class="size-4" />
            {gettext("Sign in with a passkey")}
          </.button>
        </.form>

        <%= if @plex_login_available? do %>
          <.plex_button href={~p"/auth/plex"} label={gettext("Sign in with Plex")} />
        <% end %>

        <.button
          :if={@oidc_login_available?}
          id="oidc-login"
          href={~p"/auth/oidc"}
          variant="neutral"
          class="w-full mt-4"
        >
          {gettext("Sign in with OpenID")}
        </.button>

        <%= if @jellyfin_login_available? do %>
          <.form
            :let={jf}
            for={@jellyfin_form}
            id="login_form_jellyfin"
            action={~p"/auth/jellyfin"}
            method="post"
            class="mt-4"
          >
            <.input
              field={jf[:username]}
              type="text"
              label={gettext("Jellyfin username")}
              autocomplete="off"
              spellcheck="false"
              required
            />
            <.input
              field={jf[:password]}
              type="password"
              label={gettext("Jellyfin password")}
              autocomplete="off"
              spellcheck="false"
              required
            />
            <.button class="w-full">{gettext("Sign in with Jellyfin")}</.button>
          </.form>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok,
     assign(socket,
       form: form,
       jellyfin_form: to_form(%{}, as: "jellyfin"),
       passkey_form: to_form(%{}, as: "passkey"),
       trigger_submit: false,
       plex_login_available?: PlexAuth.configured?(),
       jellyfin_login_available?: JellyfinAuth.configured?(),
       oidc_login_available?: OIDC.configured?()
     )}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  # The PasskeySignIn hook reports a ceremony that ended in the browser: the user cancelled, the
  # browser has no passkey support, or the options request failed. Only these reasons get their
  # own text; any other value gets the generic one.
  def handle_event("passkey_failed", params, socket) do
    message =
      case params do
        %{"reason" => "unsupported"} -> gettext("This browser cannot use passkeys.")
        _ -> gettext("Passkey sign-in failed. Please try again.")
      end

    {:noreply, socket |> clear_flash() |> put_flash(:error, message)}
  end

  # Client-controlled payloads — ignore anything unmatched rather than crash.
  def handle_event(_event, _params, socket), do: {:noreply, socket}
end
