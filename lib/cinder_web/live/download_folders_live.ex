defmodule CinderWeb.DownloadFoldersLive do
  @moduledoc """
  Admin maintenance panel under `/settings`: lists the `<title>.cinder-<key>` job folders in the
  explicit download folders that nothing references and clears them (issue #658, spec
  `068-orphan-download-folders`).

  Report-first. The scan and every clear run in `start_async` tasks — a download folder can hold
  terabytes — and the page only ever sends back the key of a folder it listed; the context
  re-validates and re-checks everything at delete time (`Cinder.Download.OrphanFolders.clear/3`).
  Bulk clearing covers the safe classes only; an `unmatched` folder is cleared one at a time after
  an explicit confirmation.
  """
  use CinderWeb, :live_view

  import CinderWeb.LiveHelpers, only: [humanize_bytes: 1]

  alias Cinder.Download.OrphanFolders

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(status: :loading, folders: [], referenced: 0, busy: false, confirming: nil)
     |> start_scan()}
  end

  @impl true
  def handle_async(:scan, {:ok, {:ok, %{folders: folders, referenced: referenced}}}, socket) do
    {:noreply,
     assign(socket, status: :ready, folders: folders, referenced: referenced, busy: false)}
  end

  def handle_async(:scan, {:ok, {:error, reason}}, socket) do
    {:noreply, scan_failed(socket, reason)}
  end

  def handle_async(:scan, {:exit, reason}, socket) do
    Logger.warning("download folder scan failed: #{inspect(reason)}")
    {:noreply, scan_failed(socket, :crashed)}
  end

  def handle_async(:clear, {:ok, {:ok, %{cleared: cleared, skipped: skipped}}}, socket) do
    {:noreply, socket |> flash_clear_result(cleared, skipped) |> start_scan()}
  end

  def handle_async(:clear, {:ok, {:error, reason}}, socket) do
    {:noreply, socket |> put_flash(:error, error_message(reason)) |> start_scan()}
  end

  def handle_async(:clear, {:exit, reason}, socket) do
    Logger.warning("download folder clear failed: #{inspect(reason)}")

    {:noreply,
     socket |> put_flash(:error, gettext("Couldn't clear the download folders.")) |> start_scan()}
  end

  @impl true
  def handle_event("rescan", _params, %{assigns: %{busy: false}} = socket),
    do: {:noreply, start_scan(socket)}

  def handle_event("ask_clear_safe", _params, socket),
    do: {:noreply, assign(socket, confirming: :safe)}

  def handle_event("ask_clear", %{"id" => key}, socket) do
    case folder(socket, key) do
      %{class: :unmatched} -> {:noreply, assign(socket, confirming: key)}
      _other -> {:noreply, socket}
    end
  end

  def handle_event("cancel_clear", _params, socket),
    do: {:noreply, assign(socket, confirming: nil)}

  def handle_event("clear_safe", _params, %{assigns: %{busy: false}} = socket) do
    paths = for folder <- safe_folders(socket.assigns.folders), do: folder.path
    {:noreply, start_clear(socket, paths, OrphanFolders.safe_classes())}
  end

  # Only an `:unmatched` folder is cleared one at a time; the safe classes go through the bulk
  # action, so a forged id for any other folder does nothing.
  def handle_event("clear", %{"id" => key}, %{assigns: %{busy: false}} = socket) do
    case folder(socket, key) do
      %{class: :unmatched, path: path} ->
        {:noreply, start_clear(socket, [path], [:unmatched])}

      _other ->
        {:noreply, assign(socket, confirming: nil)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  defp start_scan(socket) do
    if connected?(socket) do
      socket
      |> assign(busy: true, confirming: nil)
      |> start_async(:scan, &OrphanFolders.scan/0)
    else
      socket
    end
  end

  defp start_clear(socket, [], _allowed), do: assign(socket, confirming: nil)

  defp start_clear(socket, paths, allowed) do
    actor = socket.assigns.current_scope.user

    socket
    |> assign(busy: true, confirming: nil)
    |> start_async(:clear, fn -> OrphanFolders.clear(paths, allowed, actor) end)
  end

  # No listing is kept after a failed scan: with the roots or a client unknown, offering to clear
  # anything would be a guess.
  defp scan_failed(socket, reason),
    do: assign(socket, status: {:error, reason}, folders: [], referenced: 0, busy: false)

  defp folder(socket, key) when is_binary(key),
    do: Enum.find(socket.assigns.folders, &(&1.key == key))

  defp folder(_socket, _key), do: nil

  # Nothing cleared means no success flash: French plural form 0 also covers n = 0, so
  # "Cleared 0" would read as "1 dossier supprimé" next to the failure flash.
  defp flash_clear_result(socket, [], skipped), do: flash_skipped(socket, skipped)

  defp flash_clear_result(socket, cleared, skipped) do
    socket
    |> put_flash(
      :info,
      ngettext(
        "Cleared 1 download folder.",
        "Cleared %{count} download folders.",
        length(cleared)
      )
    )
    |> flash_skipped(skipped)
  end

  defp flash_skipped(socket, []), do: socket

  defp flash_skipped(socket, skipped) do
    {failed, changed} = Enum.split_with(skipped, &match?({_path, {:delete_failed, _}}, &1))

    socket
    |> flash_changed(changed)
    |> flash_failed(failed)
  end

  defp flash_changed(socket, []), do: socket

  defp flash_changed(socket, skipped) do
    put_flash(
      socket,
      :error,
      ngettext(
        "1 folder was left alone because it changed or is in use again.",
        "%{count} folders were left alone because they changed or are in use again.",
        length(skipped)
      )
    )
  end

  # Replaces any "left alone" flash: only one :error flash is shown, and a failed delete is the
  # more actionable one.
  defp flash_failed(socket, []), do: socket

  defp flash_failed(socket, failed) do
    put_flash(
      socket,
      :error,
      ngettext(
        "1 folder could not be deleted (permission or path check failed); see the log.",
        "%{count} folders could not be deleted (permission or path check failed); see the log.",
        length(failed)
      )
    )
  end

  defp error_message(:import_roots_not_explicit) do
    gettext(
      "Cinder only scans and clears folders you listed under “Download folders” in Settings. Without that setting it cannot tell which folders are its own, so it does nothing."
    )
  end

  defp error_message({:client_list_failed, protocol, {:unhealthy, _reason}}) do
    gettext(
      "The %{protocol} download client failed its health check, so Cinder cannot tell which folders are in use and clears nothing. Check it with its Test button in Settings.",
      protocol: protocol
    )
  end

  defp error_message({:client_list_failed, protocol, _reason}) do
    gettext(
      "The %{protocol} download client could not list its jobs, so Cinder cannot tell which folders are in use and clears nothing. Try again once it is reachable.",
      protocol: protocol
    )
  end

  defp error_message({:root_unreadable, root, _reason}),
    do: gettext("The download folder %{root} could not be read.", root: root)

  defp error_message(_other), do: gettext("Couldn't scan the download folders.")

  defp class_label(:empty), do: gettext("Empty")
  defp class_label(:library_copy), do: gettext("Library copy")
  defp class_label(:unmatched), do: gettext("Not in the library")

  defp class_badge(:empty), do: "badge-ghost"
  defp class_badge(:library_copy), do: "badge-info"
  defp class_badge(:unmatched), do: "badge-warning"

  defp class_help(:empty), do: gettext("No files inside.")

  defp class_help(:library_copy),
    do: gettext("Every video is identical to a file already in your library.")

  defp class_help(:unmatched),
    do: gettext("Holds a video that matches no library file. It may never have been imported.")

  defp hold_label(:recent), do: gettext("Changed in the last hour")
  defp hold_label(:symlink), do: gettext("Contains a symlink")
  defp hold_label(:irregular), do: gettext("Contains a special file")
  defp hold_label(:unreadable), do: gettext("Unreadable")
  defp hold_label(:too_large), do: gettext("Too many files to check")

  defp size_label(0), do: "0 B"
  defp size_label(bytes), do: humanize_bytes(bytes)

  defp safe_folders(folders),
    do: Enum.filter(folders, &(&1.class in OrphanFolders.safe_classes()))

  defp total_size(folders), do: folders |> Enum.map(& &1.size) |> Enum.sum()

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :safe, safe_folders(assigns.folders))

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
        {gettext("Leftover download folders")}
        <:subtitle>
          {gettext(
            "Cinder's own job folders in your download folders that no download, grab, movie or book refers to any more. Nothing is removed unless you clear it here."
          )}
        </:subtitle>
        <:actions>
          <.button
            type="button"
            variant="neutral"
            size="sm"
            phx-click="rescan"
            disabled={@busy}
            id="rescan-folders"
          >
            {gettext("Scan again")}
          </.button>
        </:actions>
      </.header>

      <div :if={@status == :loading or @busy} id="folders-busy" class="mb-6 flex items-center gap-2">
        <.spinner />
        <span class="text-sm">{gettext("Working through the download folders…")}</span>
      </div>

      <div
        :if={match?({:error, _}, @status)}
        id="folders-error"
        role="alert"
        class="alert alert-warning mb-6 items-start"
      >
        <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
        <p class="text-sm">{error_message(elem(@status, 1))}</p>
      </div>

      <div :if={@status == :ready}>
        <p id="folders-summary" class="mb-4 text-sm text-base-content/70">
          {ngettext(
            "%{count} job folder is still in use and was left out.",
            "%{count} job folders are still in use and were left out.",
            @referenced
          )}
        </p>

        <.empty_state
          :if={@folders == []}
          title={gettext("No leftover job folders")}
          message={gettext("Every Cinder job folder in your download folders is still in use.")}
        />

        <div :if={@safe != []} class="mb-4 flex flex-wrap items-center gap-3">
          <.button
            type="button"
            variant="danger"
            size="sm"
            phx-click="ask_clear_safe"
            disabled={@busy}
            id="clear-safe"
          >
            {ngettext(
              "Clear 1 empty or duplicate folder",
              "Clear %{count} empty or duplicate folders",
              length(@safe)
            )}
          </.button>
          <span class="text-sm text-base-content/60">{size_label(total_size(@safe))}</span>
        </div>

        <.confirm_action
          :if={@confirming == :safe}
          id="confirm-clear-safe"
          on_confirm="clear_safe"
          on_cancel="cancel_clear"
          confirm_label={gettext("Clear folders")}
          class="mb-4"
        >
          <:caveat>
            {ngettext(
              "Delete 1 folder that is empty or only holds copies of files already in your library? This cannot be undone.",
              "Delete %{count} folders that are empty or only hold copies of files already in your library? This cannot be undone.",
              length(@safe)
            )}
          </:caveat>
        </.confirm_action>

        <ul id="orphan-folders" class="space-y-3">
          <li
            :for={folder <- @folders}
            id={"folder-#{folder.key}"}
            class="card bg-base-200 shadow-sm"
          >
            <div class="card-body gap-2 p-4">
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="min-w-0">
                  <h2 class="break-all text-base font-semibold">{folder.name}</h2>
                  <p class="break-all text-xs text-base-content/60">{folder.root}</p>
                  <p class="mt-1 text-sm text-base-content/70">
                    <span :if={folder.class}>{class_help(folder.class)}</span>
                    <span :if={folder.hold}>{hold_label(folder.hold)}</span>
                  </p>
                </div>
                <div class="flex flex-wrap items-center gap-2">
                  <span class="text-sm tabular-nums text-base-content/60">
                    {size_label(folder.size)}
                  </span>
                  <span :if={folder.class} class={["badge", class_badge(folder.class)]}>
                    {class_label(folder.class)}
                  </span>
                  <span :if={folder.hold} class="badge badge-neutral">
                    {gettext("Held")}
                  </span>
                  <.button
                    :if={folder.class == :unmatched}
                    type="button"
                    variant="ghost"
                    size="sm"
                    class="text-error"
                    phx-click="ask_clear"
                    phx-value-id={folder.key}
                    disabled={@busy}
                    aria-label={gettext("Delete %{name}", name: folder.name)}
                  >
                    {gettext("Delete…")}
                  </.button>
                </div>
              </div>

              <.confirm_action
                :if={@confirming == folder.key}
                id={"confirm-clear-#{folder.key}"}
                on_confirm="clear"
                on_cancel="cancel_clear"
                value={folder.key}
                confirm_label={gettext("Delete folder")}
              >
                <:caveat>
                  {gettext(
                    "Delete %{name}? It holds a video that matches nothing in your library and may never have been imported. This cannot be undone.",
                    name: folder.name
                  )}
                </:caveat>
              </.confirm_action>
            </div>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end
