defmodule Steward.Core.Branches.Notifier do
  @moduledoc """
  Tells whoever caches a branch that it changed (after commit; Ash notifiers run
  once the transaction is durable). Transitions made through the branch's own
  process refresh its cache from the action's result, but a job, a reactor
  calling an action directly, or another node writes behind that cache, and the
  `lock_version` guard only catches the staleness when the process next writes.

  This is a plain `Phoenix.PubSub` broadcast on `"branch:<id>"`, so `Steward.Core`
  needs no knowledge of the coordinator (doc 07 §4: Core depends on nothing above
  it). A change that does not bump `lock_version` (a heartbeat's telemetry
  columns) is announced with the same version and ignored by listeners.
  """
  use Ash.Notifier

  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: Steward.Core.Branches.Branch,
        action: %{type: :update},
        data: branch
      }) do
    Phoenix.PubSub.broadcast(
      Steward.PubSub,
      topic(branch.id),
      {:branch_changed, branch.id, branch.lock_version}
    )

    :ok
  end

  def notify(_), do: :ok

  def topic(branch_id), do: "branch:#{branch_id}"
end
