defmodule CinderWeb.SettingsLabels do
  @moduledoc """
  Translates the user-facing strings that originate in the `Cinder.Settings` domain module
  (setting labels, rejection messages, help text, group headers, download-client options and
  library-kind names) and in `Cinder.Health` (probe-target and finding labels). The domain stays
  gettext-free: it emits stable English strings that double as the gettext msgids, and this
  web-layer helper translates them at render time via `t/1`.

  `known/0` registers every string `Cinder.Settings.Registry.msgids/0` and
  `Cinder.Health.msgids/0` list. The calls are dynamic, so the extractor can't see the msgids on
  its own; a private macro expands one literal `gettext_noop/1` per string at compile time, and
  `mix gettext.extract` (which recompiles) records each one. A new setting definition or probe
  target is therefore registered without editing this module.
  """
  use Gettext, backend: CinderWeb.Gettext

  @doc """
  Translate a `Cinder.Settings` English label to the active locale (passthrough if unknown). A
  `{template, bindings}` label translates the template and every binding value.
  """
  def t({template, bindings}) when is_binary(template) do
    Gettext.gettext(CinderWeb.Gettext, template, Map.new(bindings, fn {k, v} -> {k, t(v)} end))
  end

  def t(label) when is_binary(label), do: Gettext.gettext(CinderWeb.Gettext, label)

  defmacrop registered do
    for msgid <- Enum.uniq(Cinder.Settings.Registry.msgids() ++ Cinder.Health.msgids()),
        do: quote(do: gettext_noop(unquote(msgid)))
  end

  @doc "Every string the settings domain can emit, registered for extraction."
  def known, do: registered()
end
