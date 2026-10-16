defmodule Steward.Coordinator.Lifecycle do
  @moduledoc """
  A small Spark DSL for the heartbeat reconciliation matrix of doc 13 §6.8
  (doc 07 §5.0): the doc's 5 × 8 table is *declared*, one `cell` per
  `(believed, authoritative)` pair, and the extension

    * compiles the cells to `decide/3` on the declaring module, and
    * refuses to compile unless every one of the 40 pairs is declared exactly
      once (`Steward.Coordinator.Lifecycle.Transformers.VerifyCoverage`).

  The same declaration feeds the generated matrix test
  (`Steward.Coordinator.Lifecycle.MatrixTest`), so the doc table, the dispatch
  function and the test cannot drift from one another.

      defmodule Steward.Coordinator.HeartbeatMatrix do
        use Steward.Coordinator.Lifecycle

        heartbeat do
          cell believed: :open, authoritative: :proposed, reply: :proposed, actions: []
          # ... 39 more
        end
      end

      HeartbeatMatrix.decide(:merging, :merging, %{advancing: true, complete: false, compensation_persisted: true})
      #=> {%{authoritative: :merging, freeze: true}, [:renew_lease]}

  Doc 07 §5.0 names this module `Steward.Lifecycle`; it lives under
  `Steward.Coordinator` because the `boundary` library requires a boundary's
  modules to share its name prefix (the same reason `Steward.Targets` is
  `Steward.Core.Targets`).
  """
  use Spark.Dsl, default_extensions: [extensions: [Steward.Coordinator.Lifecycle.Dsl]]

  @believed [:open, :proposed, :merging, :done, :dead]
  @authoritative [:unknown, :open, :proposed, :merging, :merged, :rejected, :abandoned, :closed]
  @actions [:renew_lease, :advance_merged, :resend_merge, :alert]

  @doc "The data plane's believed states (doc 13 §6.8)."
  def believed_states, do: @believed

  @doc "The control plane's authoritative states: the seven branch states plus `unknown`."
  def authoritative_states, do: @authoritative

  @doc "Actions a cell may declare."
  def actions, do: @actions

  @doc """
  Turns a declared cell into the decision for one heartbeat.

  `progress` is `nil` (no merge progress in the heartbeat) or a map with
  `:advancing`, `:complete` and `:compensation_persisted` booleans, computed by
  the branch process from the heartbeat and the last one it saw. Two declared
  actions are conditional on it, as doc 13 §6.5 and §6.8 describe:

    * `:renew_lease`: only while `merge_progress` is advancing;
    * `:advance_merged`: only when the data plane reports the apply complete
      with the compensation persisted.

  The reply tells the data plane the authoritative state, and to freeze writes
  while the branch is `proposed` or `merging` (the data plane freezes itself on
  those states, doc 13 §6.8 rule 1).
  """
  def resolve(reply, actions, progress) do
    {%{authoritative: reply, freeze: reply in [:proposed, :merging]},
     Enum.filter(actions, &applicable?(&1, progress))}
  end

  defp applicable?(:renew_lease, %{advancing: true}), do: true
  defp applicable?(:renew_lease, _), do: false

  defp applicable?(:advance_merged, %{complete: true, compensation_persisted: true}), do: true
  defp applicable?(:advance_merged, _), do: false

  defp applicable?(_unconditional, _progress), do: true
end
