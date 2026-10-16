# The committed expectation for doc 13 §6.8, diffed against the doc's table in
# review (doc 07 §10): a change to the doc table must change this file. Each
# entry is `{believed, authoritative} => {reply, actions}`, where `actions` are
# the *declared* ones; `renew_lease` and `advance_merged` are further gated by
# merge progress (see `Steward.Coordinator.Lifecycle.resolve/3`).
#
# Reading the doc: rows are what the data plane believes, columns what the
# control plane holds. The reply always carries the authoritative state.
%{
  # --- believed open
  {:open, :unknown} => {:unknown, []},
  {:open, :open} => {:open, []},
  {:open, :proposed} => {:proposed, []},
  {:open, :merging} => {:merging, [:resend_merge]},
  {:open, :merged} => {:merged, []},
  {:open, :rejected} => {:rejected, []},
  {:open, :abandoned} => {:abandoned, []},
  {:open, :closed} => {:closed, []},
  # --- believed proposed
  {:proposed, :unknown} => {:unknown, []},
  {:proposed, :open} => {:open, []},
  {:proposed, :proposed} => {:proposed, []},
  {:proposed, :merging} => {:merging, [:resend_merge]},
  {:proposed, :merged} => {:merged, []},
  {:proposed, :rejected} => {:rejected, []},
  {:proposed, :abandoned} => {:abandoned, []},
  {:proposed, :closed} => {:closed, []},
  # --- believed merging
  {:merging, :unknown} => {:unknown, [:alert]},
  {:merging, :open} => {:open, [:alert]},
  {:merging, :proposed} => {:proposed, []},
  {:merging, :merging} => {:merging, [:renew_lease, :advance_merged]},
  {:merging, :merged} => {:merged, []},
  {:merging, :rejected} => {:rejected, [:alert]},
  {:merging, :abandoned} => {:abandoned, [:alert]},
  {:merging, :closed} => {:closed, []},
  # --- believed done
  {:done, :unknown} => {:unknown, []},
  {:done, :open} => {:open, [:alert]},
  {:done, :proposed} => {:proposed, [:alert]},
  {:done, :merging} => {:merging, [:advance_merged]},
  {:done, :merged} => {:merged, []},
  {:done, :rejected} => {:rejected, []},
  {:done, :abandoned} => {:abandoned, []},
  {:done, :closed} => {:closed, []},
  # --- believed dead
  {:dead, :unknown} => {:unknown, []},
  {:dead, :open} => {:open, [:alert]},
  {:dead, :proposed} => {:proposed, [:alert]},
  {:dead, :merging} => {:merging, [:alert]},
  {:dead, :merged} => {:merged, []},
  {:dead, :rejected} => {:rejected, []},
  {:dead, :abandoned} => {:abandoned, []},
  {:dead, :closed} => {:closed, []}
}
