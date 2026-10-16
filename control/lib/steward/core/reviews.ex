defmodule Steward.Core.Reviews do
  @moduledoc "The `Steward.Reviews` domain (doc 07 §4): reviews, review features."
  use Boundary,
    deps: [
      Steward.Core.Types,
      Steward.Core.Authz,
      Steward.Core.Targets,
      Steward.Core.Branches,
      Steward.Core.Audit
    ],
    exports: [Review, ReviewFeature]

  use Ash.Domain

  resources do
    resource Steward.Core.Reviews.Review
    resource Steward.Core.Reviews.ReviewFeature
  end
end
