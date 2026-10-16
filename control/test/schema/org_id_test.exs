defmodule Steward.Schema.OrgIdTest do
  @moduledoc """
  Doc 12 §10: every resource except the three-table allow-list carries
  `org_id` with attribute multitenancy, and every composite foreign key
  doc 12 §1/§2.2 calls for is declared `match_tenant?: true` (which is what
  makes AshPostgres emit `with: [org_id: :org_id]` in the generated
  migration — doc 17 §4's `Steward.Schema.OrgIdTest`).
  """
  use ExUnit.Case, async: true

  @domains [
    Steward.Core.Targets,
    Steward.Core.Branches,
    Steward.Core.Policies,
    Steward.Core.Reviews,
    Steward.Core.Audit
  ]

  @allow_list [Steward.Core.Targets.Org]

  # {resource, relationship} pairs whose foreign key must match the tenant
  # (org_id), per doc 12 §2.2's explicit `FOREIGN KEY (org_id, ...)` lines.
  @tenant_matched_references [
    {Steward.Core.Branches.Branch, :target},
    {Steward.Core.Branches.Branch, :principal},
    {Steward.Core.Branches.Changeset, :branch},
    {Steward.Core.Branches.Changeset, :target},
    {Steward.Core.Branches.Verdict, :changeset},
    {Steward.Core.Branches.Merge, :target},
    {Steward.Core.Branches.Merge, :branch},
    {Steward.Core.Branches.Merge, :changeset},
    {Steward.Core.Policies.Policy, :target},
    {Steward.Core.Policies.Policy, :created_by_principal},
    {Steward.Core.Reviews.Review, :changeset},
    {Steward.Core.Reviews.Review, :branch},
    {Steward.Core.Reviews.Review, :reviewer_principal}
  ]

  defp all_resources do
    @domains
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.uniq()
  end

  test "every domain is non-empty" do
    for domain <- @domains do
      assert Ash.Domain.Info.resources(domain) != [], "#{inspect(domain)} has no resources"
    end
  end

  test "every resource except the allow-list has org_id with attribute multitenancy" do
    for resource <- all_resources(), resource not in @allow_list do
      attribute = Ash.Resource.Info.attribute(resource, :org_id)

      assert attribute, "#{inspect(resource)} has no :org_id attribute"
      assert attribute.allow_nil? == false, "#{inspect(resource)}'s :org_id is nullable"

      assert Ash.Resource.Info.multitenancy_strategy(resource) == :attribute,
             "#{inspect(resource)} is not attribute-multitenant"

      assert Ash.Resource.Info.multitenancy_attribute(resource) == :org_id,
             "#{inspect(resource)}'s multitenancy attribute is not :org_id"
    end
  end

  test "the allow-list resources have no org_id / no multitenancy" do
    for resource <- @allow_list do
      assert Ash.Resource.Info.attribute(resource, :org_id) == nil,
             "#{inspect(resource)} is on the allow-list but declares :org_id"

      assert Ash.Resource.Info.multitenancy_strategy(resource) == nil,
             "#{inspect(resource)} is on the allow-list but declares multitenancy"
    end
  end

  test "allow-list is exactly the one Ash-resource exception (orgs; oban_jobs/schema_migrations aren't Ash resources)" do
    assert @allow_list == [Steward.Core.Targets.Org]
  end

  test "doc 12 §2.2's cross-table foreign keys are tenant-matched (with: [org_id: :org_id])" do
    for {resource, relationship} <- @tenant_matched_references do
      reference =
        resource
        |> AshPostgres.DataLayer.Info.references()
        |> Enum.find(&(&1.relationship == relationship))

      assert reference,
             "#{inspect(resource)} has no `references` configuration for :#{relationship}"

      assert reference.match_tenant? == true,
             "#{inspect(resource)}'s :#{relationship} reference is not tenant-matched"
    end
  end
end
