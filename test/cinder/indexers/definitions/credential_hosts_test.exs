defmodule Cinder.Indexers.Definitions.CredentialHostsTest do
  # `CredentialHosts.hosts/2` and the effective base URL (#1668; #1616 rule 5, #1620 point 10),
  # on definitions written for Cinder and read by the real loader.
  use ExUnit.Case, async: true

  alias Cinder.Indexers.Definitions.{CredentialHosts, Loader}

  defp loaded(extra) do
    %{
      "id" => "hosts",
      "name" => "Cinder Test hosts",
      "description" => "Written for Cinder's tests",
      "language" => "en-US",
      "type" => "private",
      "encoding" => "UTF-8",
      "links" => ["https://current.invalid/"],
      "legacylinks" => ["https://legacy.invalid/"],
      "settings" => [],
      "caps" => %{"modes" => %{"search" => ["q"]}},
      "search" => %{
        "rows" => %{"selector" => "tr"},
        "fields" => %{"title" => %{"selector" => "a"}}
      }
    }
    |> Map.merge(extra)
    |> Jason.encode!()
    |> Loader.load()
    |> then(fn {:ok, definition} -> definition end)
  end

  defp hosts(definition, base_url, settings \\ %{}),
    do:
      definition
      |> CredentialHosts.hosts(%{stored_url: base_url, settings: settings})
      |> Enum.sort()

  describe "effective_base_url/2" do
    test "an empty or missing stored URL and a legacy link read the first link; a current one stays" do
      definition = loaded(%{"links" => ["https://current.invalid/", "https://other.invalid/"]})

      for stored <- [nil, "", "https://legacy.invalid/"],
          cell = {stored, CredentialHosts.effective_base_url(definition, stored)},
          cell != {stored, "https://current.invalid/"},
          do: flunk("#{inspect(stored)} read #{inspect(elem(cell, 1))}")

      assert CredentialHosts.effective_base_url(definition, "https://other.invalid/") ==
               "https://other.invalid/"
    end
  end

  describe "hosts/2" do
    test "the effective base URL's host, for an empty stored URL, a legacy link and a current link" do
      definition = loaded(%{"links" => ["https://current.invalid/"], "legacylinks" => []})
      assert hosts(definition, "") == ["current.invalid"]

      # The legacy link names its own host in `legacylinks`, which counts as a URL the definition
      # names, so only the stored current link is left out of the base.
      legacy = loaded(%{})
      assert hosts(legacy, "https://legacy.invalid/") == ["current.invalid", "legacy.invalid"]

      chosen =
        loaded(%{
          "links" => ["https://current.invalid/", "https://chosen.invalid/"],
          "legacylinks" => []
        })

      assert hosts(chosen, "https://chosen.invalid/") == ["chosen.invalid", "current.invalid"]
    end

    test "a stored URL outside links and legacylinks adds its own host" do
      definition = loaded(%{"legacylinks" => []})
      assert hosts(definition, "https://stored.invalid/") == ["current.invalid", "stored.invalid"]
    end

    test "a .Config host is filled from the stored value, else from the setting's default" do
      definition =
        loaded(%{
          "legacylinks" => [],
          "settings" => [
            %{"name" => "apiurl", "type" => "text", "default" => "api.default.invalid"},
            %{"name" => "api-url", "type" => "text", "default" => "hyphen.invalid"}
          ],
          "search" => %{
            "paths" => [
              %{"path" => "https://{{ .Config.apiurl }}/api"},
              %{"path" => "https://{{- .Config.api-url -}}/api"}
            ],
            "rows" => %{"selector" => "tr"},
            "fields" => %{"title" => %{"selector" => "a"}}
          }
        })

      assert hosts(definition, "") ==
               ["api.default.invalid", "current.invalid", "hyphen.invalid"]

      assert hosts(definition, "", %{"apiurl" => "API.Stored.invalid"}) ==
               ["api.stored.invalid", "current.invalid", "hyphen.invalid"]
    end

    # The fill of `{{ .Config.sitelink }}` adds no host of its own: its value is the effective
    # base URL, whose host is always in the set.
    test "{{ .Config.sitelink }} reads the effective base URL, never a stored sitelink value" do
      definition =
        loaded(%{
          "links" => ["https://current.invalid/"],
          "legacylinks" => [],
          "settings" => [%{"name" => "sitelink", "type" => "text"}],
          "description" => "{{ .Config.sitelink }}details.php"
        })

      assert hosts(definition, "https://chosen.invalid/", %{
               "sitelink" => "https://stored-sitelink.invalid/"
             }) == ["chosen.invalid", "current.invalid"]
    end

    test "a filled host ends at the first path, query or fragment character of its value" do
      definition =
        loaded(%{
          "legacylinks" => [],
          "settings" => [%{"name" => "api", "type" => "text"}],
          "search" => %{
            "paths" => [%{"path" => "https://{{ .Config.api }}/search"}],
            "rows" => %{"selector" => "tr"},
            "fields" => %{"title" => %{"selector" => "a"}}
          }
        })

      assert hosts(definition, "", %{"api" => "API.invalid/v2?x"}) ==
               ["api.invalid", "current.invalid"]
    end

    test "a setting default that is a full URL adds its host" do
      definition =
        loaded(%{
          "legacylinks" => [],
          "settings" => [
            %{"name" => "api", "type" => "text", "default" => "https://api.invalid/v1"}
          ]
        })

      assert hosts(definition, "") == ["api.invalid", "current.invalid"]
    end

    test "a stored value that is a full URL adds its host through the fill" do
      definition =
        loaded(%{
          "legacylinks" => [],
          "settings" => [%{"name" => "api", "type" => "text"}],
          "description" => "{{ .Config.api }}search"
        })

      assert hosts(definition, "", %{"api" => "https://stored-api.invalid/"}) ==
               ["current.invalid", "stored-api.invalid"]
    end

    test "a host with another template is unknown, keyed by its raw text" do
      definition =
        loaded(%{
          "legacylinks" => [],
          "description" => "https://{{ if .Config.x }}a{{ else }}b{{ end }}.invalid/path"
        })

      # Erlang's term order puts a tuple before a binary.
      assert hosts(definition, "") ==
               [
                 {:unknown, "https://{{ if .Config.x }}a{{ else }}b{{ end }}.invalid"},
                 "current.invalid"
               ]
    end

    test "no stored value reaches an unknown host's key, userinfo or host part" do
      raw =
        "https://{{ .Config.username }}:{{ .Config.password }}@{{ .Config.region }}{{ if .Config.x }}a{{ end }}.invalid/"

      definition =
        loaded(%{
          "legacylinks" => [],
          "settings" => [
            %{"name" => "username", "type" => "text"},
            %{"name" => "password", "type" => "password"},
            %{"name" => "region", "type" => "text"}
          ],
          "description" => raw
        })

      settings = %{"username" => "alice", "password" => "hunter2", "region" => "eu"}

      assert hosts(definition, "", settings) ==
               [
                 {:unknown, "https://{{ .Config.region }}{{ if .Config.x }}a{{ end }}.invalid"},
                 "current.invalid"
               ]
    end

    test "an @ inside a template is not the end of the userinfo" do
      definition =
        loaded(%{
          "legacylinks" => [],
          "description" => ~s(https://{{ if eq .Config.x "a@b" }}a{{ end }}.invalid/)
        })

      assert hosts(definition, "") ==
               [
                 {:unknown, ~s(https://{{ if eq .Config.x "a@b" }}a{{ end }}.invalid)},
                 "current.invalid"
               ]
    end

    test "a filled userinfo never becomes the host, whatever its value holds" do
      definition =
        loaded(%{
          "legacylinks" => [],
          "settings" => [%{"name" => "password", "type" => "password"}],
          "description" => "https://user:{{ .Config.password }}@tracker.invalid/"
        })

      assert hosts(definition, "", %{"password" => "hun/ter2"}) ==
               ["current.invalid", "tracker.invalid"]
    end

    test "a stored value that is a URL with a template adds an unknown keyed by its reference" do
      definition =
        loaded(%{
          "legacylinks" => [],
          "settings" => [%{"name" => "api", "type" => "text"}],
          "description" => "{{ .Config.api }}search"
        })

      assert hosts(definition, "", %{"api" => "https://{{ x }}secret.invalid/"}) ==
               [{:unknown, "{{ .Config.api }}"}, "current.invalid"]
    end

    test "userinfo, a port, a trailing dot and upper case are dropped from a host" do
      definition =
        loaded(%{
          "legacylinks" => [],
          "description" =>
            "HTTPS://user:pass@Mixed.invalid:8443/x http://dot.invalid./ https://[::1]:9/ https:///none"
        })

      assert hosts(definition, "") ==
               ["[::1]", "current.invalid", "dot.invalid", "mixed.invalid"]
    end

    test "info setting text and legacylinks count as URLs the definition names" do
      definition =
        loaded(%{
          "settings" => [
            %{
              "name" => "help",
              "type" => "info",
              "default" => ~s(<a href="https://wiki.invalid/">x</a>)
            }
          ]
        })

      assert hosts(definition, "") == ["current.invalid", "legacy.invalid", "wiki.invalid"]
    end
  end
end
