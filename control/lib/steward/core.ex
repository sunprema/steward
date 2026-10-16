defmodule Steward.Core do
  @moduledoc """
  The domain layer: the five Ash domains (`Targets`, `Branches`, `Policies`,
  `Reviews`, `Audit`), their resources, actions, state machines, and the
  `Repo` (doc 07 §4). This boundary must never depend on `Steward.Coordinator`,
  `Steward.Jobs`, or `StewardWeb` — that is what guarantees doc 13 invariant 10
  (no remote call inside a transaction): nothing in here can reach a
  GenServer, a data-plane client, or anything web.

  Doc 07 §4 writes the domain modules as `Steward.Targets`, `Steward.Branches`,
  etc.; they are nested here as `Steward.Core.Targets` and so on because the
  `boundary` library's nested-boundary mechanism (which is how this file's
  `deps: []` guarantee is actually enforced at compile time) requires a
  sub-boundary's module name to be prefixed by its parent's. The entity names
  themselves (`Branch`, `Changeset`, `Verdict`, ...) are unchanged.
  """
  use Boundary,
    deps: [Steward.Repo],
    exports: [
      {Targets, []},
      {Branches, []},
      {Policies, []},
      {Reviews, []},
      {Audit, []}
    ]
end
