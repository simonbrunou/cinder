defmodule Cinder.Settings.Shape do
  @moduledoc false
  # What each setting-definition shape means in every pass: the form value, the value a rejected
  # submit keeps, what counts as invalid, the save plan, and how a stored row (or the captured
  # bootstrap) becomes the env value. One clause per shape, so a new shape is one set of clauses
  # here and no engine edit.
  #
  # Shapes: :text | :secret | :boolean | :legacy_toggle
  # | {:media_server, [%{value, server, module, os_env}]}
  # | {:download_client, choice} | {:choice, options} | :resolution | :positive_integer
  # | :lenient_integer | :positive_number | :size_band | :path_root | :root_list
  # | {:list, :downcase | :groups} | :timezone | :hours

  alias Cinder.Acquisition.{AnimePreferences, Parser}

  @bytes_per_gb 1_000_000_000

  @validated [
    :positive_integer,
    :positive_number,
    :size_band,
    :path_root,
    :root_list,
    :timezone,
    :hours,
    :resolution
  ]

  @doc "Whether a value of this shape can be rejected on its own."
  def validates?({tag, _options}) when tag in [:choice, :download_client], do: true
  def validates?(shape), do: shape in @validated

  @doc "The message shown when a value of this shape is rejected."
  def message(:positive_integer),
    do: "Enter a positive whole number, or leave blank for the default."

  def message(:positive_number), do: "Enter a positive number, or leave blank to disable."

  def message(:size_band),
    do: "Enter a number of GB (0 = no limit), or leave blank for the default."

  def message(shape) when shape in [:path_root, :root_list],
    do: "The top-level folder (/) is not allowed."

  def message(:timezone), do: "Enter a valid IANA timezone, such as Europe/Paris."
  def message(:hours), do: "Enter a non-negative whole number of hours."
  def message(:resolution), do: "Choose a cutoff included in the preferred resolutions list."
  def message({:download_client, _choice}), do: "Choose a listed download client."
  def message(_shape), do: nil

  # --- form ---

  @doc """
  The form value for a stored (decoded) `value`. `lookup` decodes another key, for the client
  choice that still honours its legacy 1.1 enable row.
  """
  def form_value(:boolean, value, _lookup), do: value == "true"
  def form_value(:legacy_toggle, value, _lookup), do: enabled?(value)

  def form_value({:media_server, options}, value, _lookup),
    do: shown_media_server(options, value)

  def form_value({:download_client, choice}, value, lookup) do
    case option(choice.options, value) do
      %{value: value} -> value
      nil -> if enabled?(lookup.(choice.legacy_key)), do: choice.default, else: "disabled"
    end
  end

  def form_value(_shape, value, _lookup), do: value || ""

  @doc "The value a re-rendered form keeps from a rejected submit, or `:keep` for the stored one."
  def resubmitted(shape, key, params) when shape in [:boolean, :legacy_toggle] do
    if Map.has_key?(params, key), do: {:ok, truthy?(params[key])}, else: :keep
  end

  def resubmitted({:media_server, options}, key, params) do
    if option(options, params[key]), do: {:ok, params[key]}, else: :keep
  end

  def resubmitted({:download_client, choice}, key, params) do
    value = params[key]
    if is_binary(value) and option(choice.options, value), do: {:ok, value}, else: :keep
  end

  def resubmitted(_shape, key, params) do
    case params[key] do
      value when is_binary(value) -> {:ok, value}
      _ -> :keep
    end
  end

  @doc """
  Whether a submitted `value` (nil when absent) is rejected. A blank value always passes: it
  clears the setting, except for a client choice, which must name a listed option.
  """
  def invalid?({:download_client, choice}, value),
    do: not is_nil(value) and is_nil(option(choice.options, value))

  def invalid?(:root_list, value), do: "/" in split_import_roots(value || "")
  def invalid?(:positive_integer, value), do: rejects?(value, &is_nil(positive_integer(&1)))
  def invalid?(:positive_number, value), do: rejects?(value, &(not positive_number?(&1)))

  # An explicit 0 is the unbounded opt-out (blank means "use the shipped default"), so it is valid
  # where the other parse_gb-nil values ("abc", "-2") stay rejected.
  def invalid?(:size_band, value),
    do: rejects?(value, &(is_nil(parse_gb(&1)) and not unbounded_band?(&1)))

  def invalid?(:path_root, value), do: rejects?(value, &(Path.expand(&1) == "/"))
  def invalid?(:timezone, value), do: rejects?(value, &(not valid_timezone?(&1)))
  def invalid?(:hours, value), do: rejects?(value, &(not valid_hours?(&1)))
  def invalid?({:choice, options}, value), do: rejects?(value, &(&1 not in options))

  def invalid?(:resolution, value),
    do: rejects?(value, &(String.downcase(&1) not in Parser.resolutions()))

  def invalid?(_shape, _value), do: false

  defp rejects?(value, bad?) do
    case String.trim(value || "") do
      "" -> false
      trimmed -> bad?.(trimmed)
    end
  end

  @doc """
  Adds one key's save to `{puts, deletes}`. A form key absent from `params` is left unchanged and a
  present-but-blank one clears, so a partial submit can't wipe unrelated settings. A secret's blank
  keeps the stored value; its `clear_<key>` box deletes it. An `:always` key is written on every
  save. `:read_only` and `:direct` keys are never planned.
  """
  def plan(%{save: :always, shape: :boolean, key: key}, params, {puts, deletes}),
    do: {Map.put(puts, key, params[key] || "false"), deletes}

  # Validate against the whitelist so a crafted/buggy submit can't persist a junk impl string
  # (which the media-server writer would silently ignore).
  def plan(%{save: :always, shape: {:media_server, options}, key: key}, params, {puts, deletes}),
    do: {Map.put(puts, key, shown_media_server(options, params[key])), deletes}

  def plan(%{save: :form, shape: :secret, key: key}, params, {puts, deletes}) do
    cond do
      # A typed replacement wins over a ticked Clear box: deleting the old secret AND dropping the
      # newly typed one would leave the service silently unauthenticated behind a "Settings
      # saved." flash.
      String.trim(params[key] || "") != "" ->
        {Map.put(puts, key, String.trim(params[key])), deletes}

      params["clear_" <> key] ->
        {puts, [key | deletes]}

      true ->
        {puts, deletes}
    end
  end

  def plan(%{save: :form, key: key}, params, {puts, deletes}) do
    if Map.has_key?(params, key) do
      # `|| ""` keeps a present-but-nil value (a programmatic caller) safe: String.trim/1 would
      # raise on nil.
      case String.trim(params[key] || "") do
        "" -> {puts, [key | deletes]}
        value -> {Map.put(puts, key, value), deletes}
      end
    else
      {puts, deletes}
    end
  end

  def plan(_definition, _params, acc), do: acc

  # --- env ---

  @doc """
  The env value for a stored (decoded) value. `fallback` is the bootstrap (or the shape's empty
  value) and is computed before the row lookup; `row?` says whether a row exists at all.
  """
  # A stored quota is never replaced by the bootstrap: a row that can't be used means unlimited.
  def to_env(:lenient_integer, value, fallback, row?),
    do: if(row?, do: positive_integer(value), else: fallback)

  def to_env(:timezone, value, fallback, _row?) do
    zone = value || fallback
    zone = if is_binary(zone), do: String.trim(zone), else: zone
    if valid_timezone?(zone), do: zone, else: "Etc/UTC"
  end

  # The stored option picks the impl. With none, the option its os_env selects does, else the
  # captured bootstrap (config.exs's Jellyfin in prod, the Mox mock in tests). It sits above the
  # nil clause because a missing row must still reach the os_env selection.
  def to_env({:media_server, options}, value, fallback, _row?) do
    case running_media_server(options, value) do
      %{module: module} -> module
      nil -> fallback
    end
  end

  def to_env(_shape, nil, fallback, _row?), do: fallback
  def to_env(:boolean, value, _fallback, _row?), do: value == "true"
  def to_env(:positive_integer, value, _fallback, _row?), do: positive_integer(value)

  # A stored band coerces via parse_gb, so an explicit 0 opts out to nil = unbounded.
  def to_env(:size_band, value, _fallback, _row?), do: parse_gb(value)
  def to_env({:list, :downcase}, value, _fallback, _row?), do: parse_csv_list(value)

  def to_env({:list, :groups}, value, _fallback, _row?),
    do: value |> String.split(",") |> AnimePreferences.normalize_groups()

  def to_env(:hours, value, fallback, _row?) do
    case Integer.parse(value) do
      {hours, ""} when hours >= 0 -> hours * 60 * 60
      _ -> fallback
    end
  end

  def to_env({:choice, options}, value, fallback, _row?),
    do: if(value in options, do: String.to_existing_atom(value), else: fallback)

  def to_env(:resolution, value, _fallback, _row?) do
    cutoff = value |> String.trim() |> String.downcase()
    if cutoff in Parser.resolutions(), do: cutoff, else: nil
  end

  def to_env(_shape, value, _fallback, _row?), do: value

  @doc """
  The bootstrap value a cleared setting reverts to. The captured env defaults to `[]` for an
  unset key; a root is a string and a band is positive bytes, so anything else becomes nil. A
  group list is normalized, and none is `[]`.
  """
  def from_base(:path_root, path) when is_binary(path), do: path
  def from_base(:path_root, _base), do: nil
  def from_base(:size_band, bytes) when is_integer(bytes) and bytes > 0, do: bytes
  def from_base(:size_band, _base), do: nil
  def from_base(:lenient_integer, value), do: positive_integer(value)
  def from_base({:list, :groups}, groups), do: AnimePreferences.normalize_groups(groups)
  def from_base(_shape, value), do: value

  @doc "The env value of a key with no bootstrap and no row."
  def empty(:boolean), do: false
  def empty(_shape), do: nil

  # --- parsing, shared with Cinder.Settings and its overlay ---

  @doc false
  def positive_integer(value) when is_integer(value) and value > 0, do: value

  def positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> integer
      _ -> nil
    end
  end

  def positive_integer(_value), do: nil

  # A GB string → bytes. Blank/non-numeric/≤0 ⇒ nil (unbounded): a 0 or negative band would
  # silently reject every release, so it degrades to "no limit" rather than "grab nothing".
  @doc false
  def parse_gb(nil), do: nil

  def parse_gb(value) do
    case Float.parse(String.trim(value)) do
      {gb, ""} when gb > 0 -> round(gb * @bytes_per_gb)
      _ -> nil
    end
  end

  # "1080p, 720P" → ["1080p", "720p"] / "BluRay, web" → ["bluray", "web"]. Downcased to match the
  # parser's lower-case tokens; blank/empty ⇒ nil so the scorer's per-field default applies.
  @doc false
  def parse_csv_list(nil), do: nil

  def parse_csv_list(value) do
    case value
         |> String.split(",")
         |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
         |> Enum.reject(&(&1 == "")) do
      [] -> nil
      list -> list
    end
  end

  @doc false
  def split_import_roots(value) do
    value
    |> String.split(~r/[,\n]/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  @doc false
  def valid_timezone?(zone) when is_binary(zone) do
    match?({:ok, _local}, DateTime.shift_zone(DateTime.utc_now(), String.trim(zone)))
  end

  def valid_timezone?(_zone), do: false

  # The option of a media server or download client choice whose value is `value`, or nil.
  @doc false
  def option(options, value), do: Enum.find(options, &(&1.value == value))

  @doc false
  def enabled?(nil), do: true
  def enabled?(value), do: value in ["true", "1", "on"]

  # The media server option that runs: the stored one, else the one its os_env variable selects,
  # else nil. The overlay, the form and Cinder.Settings.media_server_web_link/0 all pick through
  # it.
  @doc false
  def running_media_server(options, value),
    do: option(options, value) || os_env_option(options)

  # The type the form shows for a stored value, and saves for a submitted one: the listed value,
  # else the option its os_env selects, else the first option.
  defp shown_media_server(options, value),
    do: (running_media_server(options, value) || hd(options)).value

  # The option whose os_env variable is set (PLEX_URL for Plex): the bootstrap media server choice.
  defp os_env_option(options),
    do: Enum.find(options, &(&1.os_env && System.get_env(&1.os_env)))

  @doc false
  def truthy?(value), do: value in [true, "true", "1", "on"]

  defp positive_number?(value) do
    case Float.parse(value) do
      {number, ""} when number > 0 -> true
      _ -> false
    end
  end

  defp unbounded_band?(value) do
    case Float.parse(value) do
      {gb, ""} -> gb == 0
      _ -> false
    end
  end

  defp valid_hours?(value) do
    case Integer.parse(value) do
      {hours, ""} when hours >= 0 -> true
      _ -> false
    end
  end
end
