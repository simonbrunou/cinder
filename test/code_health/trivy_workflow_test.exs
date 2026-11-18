defmodule Cinder.CodeHealth.TrivyWorkflowTest do
  # #1486: main's push run builds no image, so .forgejo/workflows/trivy.yml builds main's image
  # every night and scans it. These tests keep its build and Trivy steps the same as the
  # container job's in ci.yml, which still scans the image of a pull request that changes an
  # image input, and keep it off the push and pull_request events and out of ci.yml's
  # concurrency group.
  use ExUnit.Case, async: true

  @trivy ".forgejo/workflows/trivy.yml"
  @ci ".forgejo/workflows/ci.yml"
  @shared ["Install Trivy", "Download the Trivy vulnerability DB"]

  test "runs every night and on demand, and on no other event" do
    workflow = read(@trivy)

    assert Map.keys(workflow) |> Enum.sort() == ~w(jobs name on)
    assert %{"schedule" => [%{"cron" => cron}], "workflow_dispatch" => nil} = workflow["on"]
    assert map_size(workflow["on"]) == 2
    assert [_minute, _hour, "*", "*", "*"] = String.split(cron, " ")
  end

  test "builds the image and runs the container job's Trivy steps, word for word" do
    [scan] = Map.values(read(@trivy)["jobs"])
    container = read(@ci)["jobs"]["container"]

    assert scan["env"] == %{
             "CINDER_IMAGE" => "cinder:trivy-${{ github.run_id }}-${{ github.run_attempt }}"
           }

    assert [checkout, build | rest] = scan["steps"]
    assert checkout == hd(container["steps"])
    assert build == step(container, &(&1["run"] == ~S(docker build -t "$CINDER_IMAGE" .)))

    for name <- @shared do
      assert step(scan, &(&1["name"] == name)) == step(container, &(&1["name"] == name)), name
    end

    assert step(scan, &trivy_action?/1) == step(container, &trivy_action?/1)

    assert List.last(rest) == %{
             "name" => "Remove the scanned image",
             "if" => "always()",
             "run" => ~S(docker image rm -f "$CINDER_IMAGE" || true)
           }

    assert length(rest) == length(@shared) + 2
  end

  defp read(path) do
    [workflow] = YamlElixir.read_all_from_string!(File.read!(path))
    workflow
  end

  defp step(job, match) do
    case Enum.filter(job["steps"], match) do
      [step] -> step
      found -> flunk("expected one matching step, found #{length(found)}")
    end
  end

  defp trivy_action?(step),
    do: String.starts_with?(step["uses"] || "", "aquasecurity/trivy-action@")
end
