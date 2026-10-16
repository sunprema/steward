defmodule Steward.Coordinator.PolicyEvaluator do
  @moduledoc """
  Turns a computed changeset into a verdict (doc 06 §5.1, step 6): the seam
  between the `Propose` reactor and the policy engine (E5).

  `evaluate/4` gets the org, the branch, the changeset and the `ChangesetReport`
  (whose `assertion_results` are the policies' results), and returns
  `{:ok, verdict}` with `outcome`, `reason`, `policy_outcome`,
  `policy_version_ids`, `control_plane_ms` and `data_plane_ms`.

  The default, `Uncovered`, is what doc 06 §5.1 prescribes when no policy is in
  scope: the target's `uncovered_changeset_verdict` (default `hold`) with reason
  `no_policy_coverage`. It is what every target gets until E5 lands. E5 replaces
  it (`config :steward, Steward.Coordinator, policy_evaluator: Module`) and the
  reactor does not change.

  The revert conflict floor (doc 13 §6.6) is *not* here: it lives in the reactor,
  "not in the policy engine" (doc 07 §5.2).
  """
  @callback evaluate(
              org_id :: String.t(),
              branch :: struct(),
              changeset :: struct(),
              report :: struct()
            ) ::
              {:ok, map()} | {:error, term()}

  def impl,
    do:
      Application.get_env(:steward, Steward.Coordinator, [])
      |> Keyword.get(:policy_evaluator, __MODULE__.Uncovered)

  defmodule Uncovered do
    @moduledoc false
    @behaviour Steward.Coordinator.PolicyEvaluator

    alias Steward.Core.Authz.System
    alias Steward.Core.Targets.TargetSettings

    @impl true
    def evaluate(org_id, branch, _changeset, report) do
      outcome = uncovered_outcome(org_id, branch.target_id)

      {:ok,
       %{
         outcome: outcome,
         reason: :no_policy_coverage,
         policy_outcome: outcome,
         policy_version_ids: [],
         control_plane_ms: 0,
         data_plane_ms: data_plane_ms(report)
       }}
    end

    # No settings row (a target registered before its settings existed) is the default: hold.
    defp uncovered_outcome(org_id, target_id) do
      case Ash.get(TargetSettings, target_id,
             tenant: org_id,
             actor: System.new(:coordinator, org_id)
           ) do
        {:ok, %{uncovered_changeset_verdict: verdict}} -> verdict
        _ -> :hold
      end
    end

    defp data_plane_ms(%{assertion_results: results}),
      do: results |> Enum.map(& &1.duration_ms) |> Enum.sum()

    defp data_plane_ms(_), do: 0
  end
end
