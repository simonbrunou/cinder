defmodule CinderWeb.DefinitionText do
  @moduledoc """
  The one lookup of the Cardigann definition codes (#1676; #1619 point 13, #1616 rules 5 to 12):
  each code the loader, the load check, the definition store, the update job, the Cardigann
  adapter and its grab return, worded through gettext (docs/agents/architecture.md "Translation
  stays in the web layer").

  - `feature/1`: a feature code, as "Not supported: %{feature}" shows it. A code that carries a
    definition keyword (`{:filter, "fuzzytime"}`) shows the keyword as written inside a translated
    phrase; the bare atoms `Cinder.Acquisition.Indexer.Cardigann.report_feature/1` makes of such
    codes (`:filter`) have their own phrase.
  - `hold_reason/1`: the reason of a held definition update.
  - `failure/1`: a Cardigann failure kind that the indexer status records, nil for a reason
    that is not one (`CinderWeb.IndexerStateText.cause/1` words the others).
  - `fetch_error/1`: the last error of the update job.
  - `run_outcome/1`: how an update run ended.
  - `grab_failure/1`: the tag of a `{:cardigann_grab, tag}` grab error.
  - `captcha_error/1`: an error of a captcha load (#1681), nil for one that is no captcha's own.

  Each function's last clause is its fallback, a text that names no code, and `fallback?/2` says
  whether a text is that fallback. Definition text (a filter or login name, a version number) is
  shown as it is and never passes through gettext.
  """
  use Gettext, backend: CinderWeb.Gettext

  alias Cinder.Acquisition.Indexer.Cardigann.Login

  @doc "The words for a feature code."
  @spec feature(term()) :: String.t()
  def feature(:flaresolverr), do: "FlareSolverr"
  def feature(:newznab), do: "Newznab"
  def feature(:torznab), do: "Torznab"
  def feature(:cardigann), do: "Cardigann"

  # The loader's feature codes (`Cinder.Indexers.Definitions.Loader.features/0`).
  def feature(:html_search), do: gettext("HTML responses")
  def feature(:json_search), do: gettext("JSON responses")
  def feature(:xml_search), do: gettext("XML responses")
  def feature(:search_post), do: gettext("searches sent by POST")
  def feature(:search_path), do: gettext("the %{name} key", name: "search.path")
  def feature(:search_path_categories), do: gettext("categories on a search path")
  def feature(:query_separator), do: gettext("a custom query separator")
  def feature(:no_inherit_inputs), do: gettext("search paths that don't inherit inputs")
  def feature(:search_headers), do: gettext("custom search headers")
  def feature(:raw_input), do: gettext("raw search inputs")
  def feature(:raw_search), do: gettext("raw searches")
  def feature(:allow_empty_inputs), do: gettext("empty search inputs")
  def feature(:keywords_filters), do: gettext("keyword filters")
  def feature(:preprocessing_filters), do: gettext("preprocessing filters")
  def feature(:search_error), do: gettext("search error pages")
  def feature(:rows_after), do: gettext("the %{name} row option", name: "after")
  def feature(:rows_count), do: gettext("the %{name} row option", name: "count")
  def feature(:rows_dateheaders), do: gettext("the %{name} row option", name: "dateheaders")
  def feature(:selector_case), do: gettext("the %{name} selector option", name: "case")
  def feature(:selector_remove), do: gettext("the %{name} selector option", name: "remove")
  def feature(:field_modifier), do: gettext("field modifiers")
  def feature(:download), do: gettext("the download block")
  def feature(:download_before), do: gettext("a request before the download")

  def feature(:download_before_pathselector),
    do: gettext("a download pre-request path selector")

  def feature(:download_before_queryseparator),
    do: gettext("a custom query separator on the download pre-request")

  def feature(:selector_remove_case),
    do:
      gettext("a selector with both the %{remove} and %{case} options",
        remove: "remove",
        case: "case"
      )

  def feature(:download_infohash), do: gettext("downloads by info hash")
  def feature(:download_post), do: gettext("downloads sent by POST")
  def feature(:download_headers), do: gettext("custom download headers")

  def feature(:download_use_before_response),
    do: gettext("download selectors that read the earlier response")

  def feature(:request_delay), do: gettext("request delays")
  def feature(:follow_redirect), do: gettext("followed redirects")
  def feature(:path_follow_redirect), do: gettext("followed redirects on a search path")
  def feature(:encoding), do: gettext("encodings other than UTF-8")
  def feature(:certificates), do: gettext("pinned certificates")
  def feature(:category_default), do: gettext("default categories")
  def feature(:tv_search_imdb), do: gettext("TV searches by IMDb id")
  def feature(:login_captcha), do: gettext("captcha")

  def feature({:row_filter, name}) when is_binary(name),
    do: gettext("the %{name} row filter", name: name)

  def feature({:filter, name}) when is_binary(name), do: gettext("the %{name} filter", name: name)
  def feature({:login, name}) when is_binary(name), do: gettext("the %{name} login", name: name)

  def feature({:setting, name}) when is_binary(name),
    do: gettext("the %{name} setting type", name: name)

  # A named code as `Cardigann.report_feature/1` reports it, by its first atom.
  def feature(:row_filter), do: gettext("a row filter")
  def feature(:filter), do: gettext("a filter")
  def feature(:login), do: gettext("logins")
  def feature(:setting), do: gettext("a setting type")

  # `{:unknown_value, slot}`, one per slot of `Loader.unknown_slots/0`.
  def feature({:unknown_value, :privacy_type}), do: gettext("an unknown privacy type")
  def feature({:unknown_value, :mode}), do: gettext("an unknown search mode")
  def feature({:unknown_value, :mode_parameter}), do: gettext("an unknown search parameter")
  def feature({:unknown_value, :category}), do: gettext("an unknown category")
  def feature({:unknown_value, :setting_type}), do: gettext("an unknown setting type")
  def feature({:unknown_value, :login_method}), do: gettext("an unknown login method")
  def feature({:unknown_value, :captcha_type}), do: gettext("an unknown captcha type")
  def feature({:unknown_value, :response_type}), do: gettext("an unknown response type")
  def feature({:unknown_value, :row_filter}), do: gettext("an unknown row filter")
  def feature({:unknown_value, :filter}), do: gettext("an unknown filter")

  # The load check's codes (`Cinder.Indexers.Definitions.LoadCheck.codes/0`).
  def feature(:dateparse_layout), do: gettext("a date layout Cinder can't read")
  def feature({:selector, :comment}), do: gettext("comments in a selector")
  def feature({:selector, :escape}), do: gettext("escapes in a selector")
  def feature({:selector, :structure}), do: gettext("a selector structure Cinder can't run")
  def feature({:selector, :template}), do: gettext("selector templates")

  def feature({:selector, :result_template}),
    do: gettext("selector templates that read the result")

  def feature({:selector, :refused}), do: gettext("a selector the page parser refuses")
  def feature({:selector, :crash}), do: gettext("selectors that crash the page parser")
  def feature({:selector, :timeout}), do: gettext("selectors too slow to check")
  def feature({:selector, :memory}), do: gettext("selectors that use too much memory")
  def feature({:selector, :output_too_large}), do: gettext("selectors with too much output")
  def feature({:regex, :dotnet_only}), do: gettext("a .NET-only regular expression")
  def feature({:regex, :invalid}), do: gettext("a regular expression Cinder can't run")
  def feature({:json, :path}), do: gettext("a JSON path Cinder can't read")
  def feature({:xml_selector, :invalid}), do: gettext("an XML selector Cinder can't read")

  def feature({:xml_selector, name}) when is_binary(name),
    do: gettext("the XML selector :%{name}", name: name)

  def feature({:certificates, :malformed}), do: gettext("a malformed pinned certificate")

  # The Cardigann adapter's own codes for a copy that does not run (`Cardigann.copy_codes/0`).
  def feature(:definition_unchecked), do: gettext("a definition not checked yet")
  def feature(:definition_fails), do: gettext("a definition that no longer loads")
  def feature(:definition_missing), do: gettext("a missing definition")
  def feature(:definition_switched), do: gettext("a definition switched meanwhile")

  def feature(_code), do: gettext("a feature this version of Cinder doesn't have")

  @doc "The words for the reason a definition update is held."
  @spec hold_reason(term()) :: String.t()
  def hold_reason(:undecryptable), do: gettext("the saved credentials can't be decrypted")
  def hold_reason(:fails), do: gettext("the new copy fails to load")

  def hold_reason({:not_supported, feature}),
    do: gettext("not supported: %{feature}", feature: feature(feature))

  def hold_reason(:hosts), do: gettext("it would send credentials to new hosts")
  def hold_reason(:certificates), do: gettext("its certificates changed")
  def hold_reason(:removed_credential), do: gettext("it removes a secret setting")
  def hold_reason(:retyped_credential), do: gettext("it changes the type of a secret setting")

  def hold_reason({:needs_newer_cinder, version}) when is_integer(version),
    do: gettext("needs a newer Cinder (v%{version})", version: version)

  def hold_reason(_reason), do: gettext("a reason this version of Cinder doesn't know")

  @doc """
  The cause of a Cardigann failure kind the indexer status records (#1671), or nil for any other
  reason.
  """
  @spec failure(term()) :: String.t() | nil
  def failure(:parser_failed),
    do: gettext("The page parser crashed, timed out or ran out of memory")

  def failure(:regex_limit), do: gettext("A regular expression hit its limit")
  def failure(:filter_output_cap), do: gettext("A filter chain hit its output cap")
  def failure(:forbidden_address), do: gettext("The indexer's address is not allowed")

  def failure(:secret_host),
    do: gettext("Refused: a credential would go to a host the definition does not name")

  def failure(:too_many_redirects), do: gettext("Too many redirects")
  def failure(:definition_error), do: gettext("The definition's templates failed")

  # The Test outcomes of a login that met its image captcha (#1681).
  def failure(:captcha_required), do: gettext("Login needs a captcha")
  def failure(:captcha_expired), do: gettext("The captcha expired: show a new one")

  # A Cloudflare or DDoS-Guard challenge and the FlareSolverr call it led to (#1682).
  def failure(:cloudflare_challenge), do: gettext("Cloudflare challenge")
  def failure(:flaresolverr_url_not_set), do: gettext("FlareSolverr URL not set")
  def failure(:flaresolverr_failed), do: gettext("FlareSolverr failed")
  def failure(:flaresolverr_off_host), do: gettext("FlareSolverr answered from another site")
  def failure(_reason), do: nil

  @doc """
  The words for an error of a captcha load (#1681) that is the captcha's own
  (`Cinder.Acquisition.Indexer.Cardigann.captcha_errors/0`), or an HTTP status the image or the
  login page answered; nil for any other reason, which `CinderWeb.IndexerStateText.cause/1`
  words.
  """
  @spec captcha_error(term()) :: String.t() | nil
  def captcha_error(:no_captcha), do: gettext("This indexer's login asks for no captcha.")
  def captcha_error(:captcha_not_found), do: gettext("The site sent no captcha image.")

  def captcha_error({:captcha_image, :type}),
    do: gettext("The captcha image could not be shown: it is no PNG, JPEG, GIF or WebP image.")

  def captcha_error({:captcha_image, :too_large}),
    do:
      gettext("The captcha image could not be shown: it is larger than %{size} MiB.",
        size: div(Login.max_image_bytes(), 1_048_576)
      )

  def captcha_error({:http_status, status}) when is_integer(status),
    do: gettext("The site answered HTTP %{status} for the captcha.", status: status)

  def captcha_error(_reason), do: nil

  @doc """
  The words for the tag of a `{:cardigann_grab, tag}` grab error
  (`Cinder.Acquisition.Indexer.Cardigann.Grab.failure_tags/0`).
  """
  @spec grab_failure(term()) :: String.t()
  def grab_failure(tag)
      when tag in [
             :parser_failed,
             :regex_limit,
             :filter_output_cap,
             :cloudflare_challenge,
             :flaresolverr_url_not_set,
             :flaresolverr_failed,
             :flaresolverr_off_host
           ],
      do: failure(tag)

  def grab_failure(:secret_host), do: failure(:secret_host)
  def grab_failure(:no_link), do: gettext("The details page held no download link")
  def grab_failure(:deadline), do: gettext("The grab ran past its time limit")
  def grab_failure(:definition_unchecked), do: gettext("The definition is not checked yet")
  def grab_failure(:page_too_large), do: gettext("The details page was too large")
  def grab_failure(:bad_page), do: gettext("The details page could not be read")
  def grab_failure(:before_failed), do: gettext("The site's pre-download request failed")

  def grab_failure(:infohash_not_found),
    do: gettext("The info hash or the title is missing where the definition reads them")

  def grab_failure(:bad_headers),
    do: gettext("The definition's download headers could not be sent")

  def grab_failure(:definition_error),
    do: gettext("A download selector holds a secret setting, so the page was not read")

  def grab_failure(:login_failed), do: gettext("The site's login failed before the download")

  def grab_failure(_tag), do: gettext("The grab failed")

  @doc "The words for the last error of the definitions update job."
  @spec fetch_error(term()) :: String.t()
  def fetch_error({:http_status, status}) when is_integer(status),
    do: gettext("GitHub answered HTTP %{status}", status: status)

  def fetch_error(:timeout), do: gettext("GitHub did not answer in time")
  def fetch_error(:too_large), do: gettext("GitHub's answer was too large")
  def fetch_error(:transport), do: gettext("GitHub could not be reached")
  def fetch_error(:no_master_ref), do: gettext("GitHub named no master branch")
  def fetch_error(:invalid_commit), do: gettext("GitHub named a commit Cinder can't read")
  def fetch_error(:archive_corrupt), do: gettext("The definitions archive is damaged")

  def fetch_error(:archive_entry_limit),
    do: gettext("The definitions archive holds too many files")

  def fetch_error(:archive_entry_unsafe),
    do: gettext("The definitions archive holds a link or a file outside its folder")

  def fetch_error(:archive_layout),
    do: gettext("The definitions archive has an unexpected layout")

  def fetch_error(:archive_size_limit),
    do: gettext("The definitions archive unpacks to more than Cinder's limit")

  def fetch_error(:file_too_large), do: gettext("A definition file is larger than Cinder's limit")
  def fetch_error(:versions_missing), do: gettext("The definitions archive has no VERSIONS file")
  def fetch_error(:versions_unreadable), do: gettext("The VERSIONS file can't be read")
  def fetch_error(:crashed), do: gettext("The update crashed")
  def fetch_error(_tag), do: gettext("The update failed")

  @doc "How an update run ended, as the line under the indexers table says it."
  @spec run_outcome(term()) :: String.t()
  def run_outcome(:applied), do: gettext("Indexer definitions updated.")
  def run_outcome(:unchanged), do: gettext("Indexer definitions are up to date.")
  def run_outcome(:cinder_too_old), do: gettext("Cinder is too old for current definitions.")
  def run_outcome(:shrank), do: gettext("The upstream answer shrank, so it was not applied.")

  def run_outcome(:first_too_small),
    do: gettext("The upstream answer holds too few definitions, so it was not applied.")

  def run_outcome({:failed, tag}),
    do: gettext("Indexer definitions update failed: %{error}.", error: fetch_error(tag))

  def run_outcome(_outcome), do: gettext("Indexer definitions update ended.")

  @doc "Whether `text` is the fallback of `function` (`:feature`, `:hold_reason`, ...)."
  @spec fallback?(atom(), String.t() | nil) :: boolean()
  def fallback?(function, text) when function in [:failure, :captcha_error], do: text == nil
  def fallback?(function, text), do: text == apply(__MODULE__, function, [:__no_such_code__])
end
