defmodule Steward.Coordinator.HeartbeatMatrix do
  @moduledoc """
  Doc 13 §6.8's reconciliation table, declared (doc 07 §5.0). One cell per
  `(believed, authoritative)` pair; the comment on each is the doc's cell text
  for the data plane's reaction, and `actions` is what the *control plane* does
  in addition to replying. The reply always carries the authoritative state:
  "the data plane **must** adopt the authoritative state. It never argues."

  `:alert` cells are states the design says cannot happen. They write a
  `heartbeat.anomaly` event and page; they never repair, because each implies a
  bug or a lost checkpoint (doc 13 §6.8, doc 07 §5.3).

  The data plane's half of the same table is `Steward.FakeDataPlane.Matrix`
  (test support) and, in production, `steward-engine` (doc 05).
  """
  use Steward.Coordinator.Lifecycle

  heartbeat do
    # --- believed open ------------------------------------------------------
    # mark dead, GC overlay
    cell(believed: :open, authoritative: :unknown, reply: :unknown, actions: [])
    # no-op
    cell(believed: :open, authoritative: :open, reply: :open, actions: [])
    # freeze writes, write freeze marker
    cell(believed: :open, authoritative: :proposed, reply: :proposed, actions: [])
    # freeze; expect merge instruction (re-sent by CP)
    cell(believed: :open, authoritative: :merging, reply: :merging, actions: [:resend_merge])
    # freeze; set done; GC after retention
    cell(believed: :open, authoritative: :merged, reply: :merged, actions: [])
    cell(believed: :open, authoritative: :rejected, reply: :rejected, actions: [])
    cell(believed: :open, authoritative: :abandoned, reply: :abandoned, actions: [])
    # mark dead, GC overlay
    cell(believed: :open, authoritative: :closed, reply: :closed, actions: [])

    # --- believed proposed --------------------------------------------------
    # mark dead, GC overlay
    cell(believed: :proposed, authoritative: :unknown, reply: :unknown, actions: [])
    # unfreeze writes; drop freeze marker
    cell(believed: :proposed, authoritative: :open, reply: :open, actions: [])
    # no-op
    cell(believed: :proposed, authoritative: :proposed, reply: :proposed, actions: [])
    # expect merge instruction (re-sent by CP)
    cell(believed: :proposed, authoritative: :merging, reply: :merging, actions: [:resend_merge])
    # set done
    cell(believed: :proposed, authoritative: :merged, reply: :merged, actions: [])
    cell(believed: :proposed, authoritative: :rejected, reply: :rejected, actions: [])
    cell(believed: :proposed, authoritative: :abandoned, reply: :abandoned, actions: [])
    # mark dead, GC
    cell(believed: :proposed, authoritative: :closed, reply: :closed, actions: [])

    # --- believed merging ---------------------------------------------------
    # mark dead; **alert** (compensation may exist for an unknown branch)
    cell(believed: :merging, authoritative: :unknown, reply: :unknown, actions: [:alert])
    # **alert**; stop apply if before compensation checkpoint; otherwise continue and alert
    cell(believed: :merging, authoritative: :open, reply: :open, actions: [:alert])

    # stop apply if before checkpoint; otherwise continue (CP state is stale: CP will see progress and correct)
    cell(believed: :merging, authoritative: :proposed, reply: :proposed, actions: [])
    # renew lease; report progress; CP advances to `merged` if progress complete
    cell(
      believed: :merging,
      authoritative: :merging,
      reply: :merging,
      actions: [:renew_lease, :advance_merged]
    )

    # set done
    cell(believed: :merging, authoritative: :merged, reply: :merged, actions: [])
    # **alert** (should be impossible after checkpoint)
    cell(believed: :merging, authoritative: :rejected, reply: :rejected, actions: [:alert])
    # **alert** (abandon of `merging` is refused)
    cell(believed: :merging, authoritative: :abandoned, reply: :abandoned, actions: [:alert])
    # mark dead, GC
    cell(believed: :merging, authoritative: :closed, reply: :closed, actions: [])

    # --- believed done ------------------------------------------------------
    # mark dead, GC
    cell(believed: :done, authoritative: :unknown, reply: :unknown, actions: [])
    # **alert** (CP lost a terminal transition)
    cell(believed: :done, authoritative: :open, reply: :open, actions: [:alert])
    cell(believed: :done, authoritative: :proposed, reply: :proposed, actions: [:alert])
    # report progress complete; CP advances
    cell(believed: :done, authoritative: :merging, reply: :merging, actions: [:advance_merged])
    # no-op
    cell(believed: :done, authoritative: :merged, reply: :merged, actions: [])
    cell(believed: :done, authoritative: :rejected, reply: :rejected, actions: [])
    cell(believed: :done, authoritative: :abandoned, reply: :abandoned, actions: [])
    # mark dead, GC
    cell(believed: :done, authoritative: :closed, reply: :closed, actions: [])

    # --- believed dead ------------------------------------------------------
    # GC when safe
    cell(believed: :dead, authoritative: :unknown, reply: :unknown, actions: [])
    # **alert**
    cell(believed: :dead, authoritative: :open, reply: :open, actions: [:alert])
    cell(believed: :dead, authoritative: :proposed, reply: :proposed, actions: [:alert])
    cell(believed: :dead, authoritative: :merging, reply: :merging, actions: [:alert])
    # GC
    cell(believed: :dead, authoritative: :merged, reply: :merged, actions: [])
    cell(believed: :dead, authoritative: :rejected, reply: :rejected, actions: [])
    cell(believed: :dead, authoritative: :abandoned, reply: :abandoned, actions: [])
    cell(believed: :dead, authoritative: :closed, reply: :closed, actions: [])
  end
end
