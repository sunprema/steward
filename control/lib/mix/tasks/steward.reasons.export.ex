defmodule Mix.Tasks.Steward.Reasons.Export do
  @shortdoc "Regenerates contracts/reasons.yaml's `reasons:` list from Steward.Core.Types.LifecycleReason"

  @moduledoc """
  Doc 12 §3: the Elixir `LifecycleReason` enum is the source CI regenerates
  `contracts/reasons.yaml` from; this task does the regeneration, and CI
  fails the build if running it produces a diff. Only the `reasons:` block
  is rewritten — the file's header comment and its `events:`/`sqlstates:`
  sections (owned elsewhere) are left untouched.
  """
  use Mix.Task

  alias Steward.Core.Types.LifecycleReason

  @impl Mix.Task
  def run(_args) do
    path = Path.expand("../contracts/reasons.yaml", File.cwd!())
    original = File.read!(path)

    [before, rest] = split_once(original, "\nreasons:\n")
    [_old_reasons, after_reasons] = split_once(rest, "\n\n# Domain event types")

    updated =
      before <> "\nreasons:\n" <> render_reasons() <> "\n# Domain event types" <> after_reasons

    File.write!(path, updated)
    Mix.shell().info("Wrote #{Path.relative_to_cwd(path)}")
  end

  defp split_once(string, marker) do
    case String.split(string, marker, parts: 2) do
      [_, _] = parts -> parts
      _ -> raise "could not find #{inspect(marker)} in contracts/reasons.yaml"
    end
  end

  defp render_reasons do
    LifecycleReason.metadata()
    |> Enum.map(&render_reason/1)
    |> Enum.join("\n")
  end

  defp render_reason({name, meta}) do
    states_from = meta.states_from |> Enum.map(&to_string/1) |> Enum.join(", ")
    used_by = meta.used_by |> Enum.map(&to_string/1) |> Enum.join(", ")

    """
      - name: #{name}
        description: #{LifecycleReason.description(name)}
        terminal: #{meta.terminal}
        states_from: [#{states_from}]
        used_by: [#{used_by}]
    """
  end
end
