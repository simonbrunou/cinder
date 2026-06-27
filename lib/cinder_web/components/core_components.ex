defmodule CinderWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: CinderWeb.Gettext

  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.JS

  @image_base "https://image.tmdb.org/t/p/"

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button
          type="button"
          class="group self-start cursor-pointer rounded focus-visible:outline-2 focus-visible:outline-current"
          aria-label={gettext("close")}
        >
          <.icon
            name="hero-x-mark"
            class="size-5 opacity-40 group-hover:opacity-70 group-focus-visible:opacity-70"
          />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global,
    include: ~w(href navigate patch method download name value disabled type form)

  attr :class, :any, default: nil, doc: "extra classes appended to the computed button classes"
  attr :variant, :string, default: "primary", values: ~w(primary neutral ghost danger warning)
  attr :size, :string, default: "md", values: ~w(xs sm md)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :btn_class, [
        "btn",
        button_variant(assigns.variant),
        button_size(assigns.size),
        assigns.class
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@btn_class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@btn_class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  defp button_variant("primary"), do: "btn-primary"
  # plain daisyUI button (subtle surface) — the unobtrusive secondary action
  defp button_variant("neutral"), do: nil
  defp button_variant("ghost"), do: "btn-ghost"
  defp button_variant("danger"), do: "btn-error"
  defp button_variant("warning"), do: "btn-warning"

  defp button_size("md"), do: nil
  defp button_size("sm"), do: "btn-sm"
  defp button_size("xs"), do: "btn-xs"

  @doc """
  A centered empty / zero state: icon, title, optional message, optional `:cta` slot.
  `variant="search-error"` renders the failed-search treatment (error icon + colour),
  distinct from an ordinary no-results state.

  ## Examples

      <.empty_state title="No grabs" message="In-flight downloads will show here." icon="hero-arrow-down-tray" />
      <.empty_state variant="search-error" title="Search failed" message="TMDB didn't respond. Try again." />
  """
  attr :title, :string, required: true
  attr :message, :string, default: nil
  attr :icon, :string, default: "hero-inbox"
  attr :variant, :string, default: "default", values: ~w(default search-error)
  slot :cta

  def empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center gap-3 py-12 text-center">
      <.icon
        name={if @variant == "search-error", do: "hero-exclamation-triangle", else: @icon}
        class={["size-10", (@variant == "search-error" && "text-error") || "text-base-content/40"]}
      />
      <div>
        <p class="font-medium">{@title}</p>
        <p :if={@message} class="mt-1 text-sm text-base-content/70">{@message}</p>
      </div>
      <div :if={@cta != []}>{render_slot(@cta)}</div>
    </div>
    """
  end

  @doc """
  Inline two-step confirmation for a destructive action: a `role="alert"` box with a
  caveat, a confirm button (emits `on_confirm`), and a cancel button (emits `on_cancel`).
  Markup only — the caller drives visibility with `:if` and keeps its own "confirming"
  assign and event names, so adoption preserves each page's existing wiring.

  ## Examples

      # in a template, caller controls visibility with :if and its own @confirming assign:
      # <.confirm_action
      #   :if={@confirming == {:delete, m.id}}
      #   id={"confirm-delete-\#{m.id}"}
      #   on_confirm="confirm_delete"
      #   on_cancel="dismiss_confirm"
      #   value={m.id}
      #   confirm_label="Delete"
      # >
      #   <:caveat>Delete this movie's record? (Library files are left on disk.)</:caveat>
      # </.confirm_action>
  """
  attr :id, :string, required: true
  attr :on_confirm, :string, required: true
  attr :on_cancel, :string, required: true
  attr :value, :any, default: nil, doc: "phx-value-id sent with the confirm event (nil = omitted)"
  attr :confirm_label, :string, default: nil
  attr :cancel_label, :string, default: nil
  attr :variant, :string, default: "error", values: ~w(error warning)
  attr :class, :any, default: nil, doc: "extra classes on the root (e.g. caller's outer margin)"

  attr :checkbox_event, :string,
    default: nil,
    doc: "optional phx-click for an inline 'also do X' checkbox; nil = no checkbox"

  attr :checkbox_checked, :boolean, default: false, doc: "checked state of the optional checkbox"
  attr :checkbox_label, :string, default: nil, doc: "label for the optional checkbox"
  slot :caveat, required: true

  def confirm_action(assigns) do
    ~H"""
    <div
      id={@id}
      role="alert"
      aria-live="assertive"
      class={[
        "alert flex flex-col items-start gap-2",
        @variant == "warning" && "alert-warning",
        @variant == "error" && "alert-error",
        @class
      ]}
    >
      <label
        :if={@checkbox_event}
        class="flex cursor-pointer items-center gap-2 text-sm"
      >
        <input
          type="checkbox"
          class="checkbox checkbox-sm"
          phx-click={@checkbox_event}
          checked={@checkbox_checked}
        />
        <span>{@checkbox_label}</span>
      </label>
      <p class="text-sm">{render_slot(@caveat)}</p>
      <div class="flex flex-wrap gap-2">
        <.button
          type="button"
          variant={if @variant == "warning", do: "warning", else: "danger"}
          phx-click={@on_confirm}
          phx-value-id={@value}
          phx-disable-with={gettext("Working…")}
        >
          {@confirm_label || gettext("Confirm")}
        </.button>
        <.button type="button" variant="ghost" phx-click={@on_cancel}>
          {@cancel_label || gettext("Cancel")}
        </.button>
      </div>
    </div>
    """
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://hexdocs.pm/phoenix_html/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            aria-invalid={@errors != [] && "true"}
            aria-describedby={@errors != [] && @id && "#{@id}-error"}
            {@rest}
          />{@label}
        </span>
      </label>
      <div :if={@errors != []} id={@id && "#{@id}-error"}>
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@errors != [] && @id && "#{@id}-error"}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <div :if={@errors != []} id={@id && "#{@id}-error"}>
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@errors != [] && @id && "#{@id}-error"}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <div :if={@errors != []} id={@id && "#{@id}-error"}>
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          aria-invalid={@errors != [] && "true"}
          aria-describedby={@errors != [] && @id && "#{@id}-error"}
          {@rest}
        />
      </label>
      <div :if={@errors != []} id={@id && "#{@id}-error"}>
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-xl font-semibold leading-tight">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  A small inline loading spinner (respects `prefers-reduced-motion`).

      <.spinner label="Checking services…" />
  """
  attr :class, :any, default: "size-5"
  attr :label, :string, default: "Loading…"

  def spinner(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-2 text-base-content/70">
      <.icon name="hero-arrow-path" class={["motion-safe:animate-spin", @class]} />
      <span :if={@label} class="text-sm">{@label}</span>
    </span>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(CinderWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(CinderWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  A status badge with an icon **and** a text label — never colour alone (a11y). One
  source of truth for every pipeline / request / episode / grab / health state.

  `kind` selects the vocabulary; `status` is the state within it. Derived-state callers
  (episode, grab) resolve the atom themselves and pass it; `health` passes `:ok` or
  `{:error, reason}` (the reason becomes the hover title).

  ## Examples

      <.status_badge kind={:movie} status={:downloading} />
      <.status_badge kind={:request} status={:pending} />
      <.status_badge kind={:episode} status={:wanted} />
      <.status_badge kind={:grab} status={:downloaded} />
      <.status_badge kind={:health} status={{:error, :timeout}} />
  """
  attr :kind, :atom, required: true, values: [:movie, :request, :episode, :grab, :health]
  attr :status, :any, required: true
  attr :class, :any, default: nil

  def status_badge(assigns) do
    {label, color, icon} = badge_spec(assigns.kind, assigns.status)

    assigns =
      assign(assigns,
        label: label,
        color: color,
        icon: icon,
        title: badge_title(assigns.kind, assigns.status)
      )

    ~H"""
    <span class={["badge badge-sm gap-1", @color, @class]} title={@title}>
      <.icon name={@icon} class="size-3.5" />{@label}
    </span>
    """
  end

  # movie pipeline status
  defp badge_spec(:movie, :requested), do: {gettext("Requested"), "badge-neutral", "hero-clock"}

  defp badge_spec(:movie, :searching),
    do: {gettext("Searching"), "badge-info", "hero-magnifying-glass"}

  defp badge_spec(:movie, :downloading),
    do: {gettext("Downloading"), "badge-info", "hero-arrow-down-tray"}

  defp badge_spec(:movie, :downloaded), do: {gettext("Downloaded"), "badge-accent", "hero-check"}

  defp badge_spec(:movie, :available),
    do: {gettext("Available"), "badge-success", "hero-check-circle"}

  defp badge_spec(:movie, :no_match),
    do: {gettext("No match"), "badge-warning", "hero-magnifying-glass"}

  defp badge_spec(:movie, :search_failed),
    do: {gettext("Search failed"), "badge-error", "hero-exclamation-triangle"}

  defp badge_spec(:movie, :import_failed),
    do: {gettext("Import failed"), "badge-error", "hero-exclamation-triangle"}

  defp badge_spec(:movie, :cancelled), do: {gettext("Cancelled"), "badge-error", "hero-x-circle"}

  # request / composite discovery state
  defp badge_spec(:request, :pending), do: {gettext("Pending"), "badge-warning", "hero-clock"}
  defp badge_spec(:request, :approved), do: {gettext("Approved"), "badge-info", "hero-check"}
  defp badge_spec(:request, :denied), do: {gettext("Denied"), "badge-error", "hero-x-circle"}

  defp badge_spec(:request, :available),
    do: {gettext("Available"), "badge-success", "hero-check-circle"}

  # episode derived-state
  defp badge_spec(:episode, :available),
    do: {gettext("Available"), "badge-success", "hero-check-circle"}

  defp badge_spec(:episode, :downloading),
    do: {gettext("Downloading"), "badge-info", "hero-arrow-down-tray"}

  defp badge_spec(:episode, :wanted), do: {gettext("Wanted"), "badge-warning", "hero-eye"}
  defp badge_spec(:episode, :upcoming), do: {gettext("Upcoming"), "badge-ghost", "hero-calendar"}

  # grab state
  defp badge_spec(:grab, :downloading),
    do: {gettext("Downloading"), "badge-info", "hero-arrow-down-tray"}

  defp badge_spec(:grab, :downloaded), do: {gettext("Downloaded"), "badge-success", "hero-check"}

  # service health
  defp badge_spec(:health, :ok), do: {gettext("OK"), "badge-success", "hero-check-circle"}

  defp badge_spec(:health, {:error, _reason}),
    do: {gettext("Unreachable"), "badge-error", "hero-exclamation-triangle"}

  # safe fallback — a view must never crash over an unmapped state
  defp badge_spec(_kind, status),
    do: {humanize_status(status), "badge-neutral", "hero-question-mark-circle"}

  defp badge_title(:health, {:error, reason}), do: inspect(reason)
  defp badge_title(_kind, _status), do: nil

  defp humanize_status(status) when is_atom(status),
    do: status |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  defp humanize_status(status), do: inspect(status)

  @doc """
  A poster card for a movie or TV result/record. Renders the TMDB poster (or a
  "No poster" placeholder), the title + optional year, an optional film/TV corner
  chip, and an action affordance via the inner block (Add button, status badge,
  season-picker link, admin controls). Single source of truth for the discover/
  library poster card — replaces the duplicated `movie_card`/`series_card`.

  `poster_path` is the TMDB path fragment (`/abc.jpg`); the full URL is built here.

  ## Examples

      <.media_card poster_path={m.poster_path} title={m.title} year={m.year} type={:movie}>
        <.status_badge kind={:movie} status={m.status} />
      </.media_card>
  """
  attr :poster_path, :string, default: nil
  attr :title, :string, required: true
  attr :year, :integer, default: nil
  attr :type, :atom, default: nil, values: [nil, :movie, :tv]
  slot :inner_block

  def media_card(assigns) do
    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <figure class="relative">
        <img
          :if={@poster_path}
          src={poster_url(@poster_path)}
          alt={@title}
          loading="lazy"
          decoding="async"
          class="aspect-[2/3] w-full object-cover"
        />
        <div
          :if={!@poster_path}
          class="grid aspect-[2/3] w-full place-items-center bg-base-300 text-sm text-base-content/70"
        >
          {gettext("No poster")}
        </div>
        <span
          :if={@type}
          class="badge badge-sm absolute left-2 top-2 gap-1 border-0 bg-base-100"
        >
          <.icon name={type_icon(@type)} class="size-3" />{type_label(@type)}
        </span>
      </figure>
      <div class="card-body gap-2 p-3">
        <h3 class="text-sm font-semibold leading-tight">
          {@title}
          <span :if={@year} class="font-normal text-base-content/70">({@year})</span>
        </h3>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp type_icon(:movie), do: "hero-film"
  defp type_icon(:tv), do: "hero-tv"
  defp type_label(:movie), do: gettext("Film")
  defp type_label(:tv), do: gettext("TV")

  @doc """
  Builds a full TMDB image URL from a `poster_path` fragment (`/abc.jpg`). `size`
  is the TMDB image size token — `"w342"` for cards (default), `"w92"` for thumbnails.
  """
  def poster_url(path, size \\ "w342"), do: @image_base <> size <> path

  @doc """
  The preferred-language `<select>` shared across the request/edit surfaces: three
  options (Original / French / Any) with values `"original"` / `"french"` / `"any"`.
  `value` is the currently-selected language (the matching option gets `selected`);
  pass `original_label` to show a language-qualified label like "Original (English)".
  The enclosing `<form>` carries the `phx-change`/`phx-submit` binding.

      <.language_select value={@preferred_language} />
      <.language_select original_label={original_option_label(@original_language)} />
  """
  attr :value, :string, default: nil
  attr :class, :any, default: "select select-sm w-full"
  attr :original_label, :string, default: nil
  attr :rest, :global

  def language_select(assigns) do
    ~H"""
    <select
      name="preferred_language"
      class={@class}
      aria-label={gettext("Preferred language")}
      {@rest}
    >
      <option value="original" selected={@value == "original"}>
        {@original_label || gettext("Original")}
      </option>
      <option value="french" selected={@value == "french"}>{gettext("French")}</option>
      <option value="any" selected={@value == "any"}>{gettext("Any language")}</option>
    </select>
    """
  end

  @doc """
  Human label for a TV season number: "Specials" for season 0, "Season N" otherwise.
  """
  def season_label(0), do: gettext("Specials")
  def season_label(n), do: gettext("Season %{number}", number: n)
end
