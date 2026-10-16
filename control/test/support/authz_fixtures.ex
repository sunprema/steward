defmodule Steward.AuthzFixtures do
  @moduledoc """
  Synthetic orgs, principals, targets and lifecycle rows for authorisation
  tests (doc 18 §7: synthetic data only). Setup writes run with authorisation
  off, because it is the policies under test that must be exercised, not the
  fixtures' own writes.
  """
  alias Steward.Core.{Authz, Branches, Policies, Targets}

  def uuid, do: Ecto.UUID.generate()

  def org(slug \\ nil) do
    slug = slug || "org-#{System.unique_integer([:positive])}"

    Targets.Org
    |> Ash.Changeset.for_create(:create, %{slug: slug, name: slug}, authorize?: false)
    |> Ash.create!()
  end

  def principal(org, kind, opts \\ []) do
    slug = Keyword.get(opts, :slug, "#{kind}-#{System.unique_integer([:positive])}")

    Targets.Principal
    |> Ash.Changeset.for_create(
      :create,
      %{
        kind: kind,
        slug: slug,
        display_name: slug,
        org_admin: Keyword.get(opts, :org_admin, false)
      },
      tenant: org.id,
      authorize?: false
    )
    |> Ash.create!()
  end

  def target(org, creator, opts \\ []) do
    slug = "target-#{System.unique_integer([:positive])}"

    Targets.Target
    |> Ash.Changeset.for_create(
      :create,
      %{
        slug: slug,
        name: slug,
        kind: :postgres,
        credential_ref: "env://SYNTHETIC",
        created_by: creator.id,
        data_plane_id: opts[:data_plane_id]
      },
      tenant: org.id,
      authorize?: false
    )
    |> Ash.create!()
  end

  def data_plane(org, opts \\ []) do
    Targets.DataPlane
    |> Ash.Changeset.for_create(
      :create,
      %{
        region: "synthetic-1",
        chart_version: "0.0.0",
        cert_serial:
          Keyword.get(opts, :cert_serial, "serial-#{System.unique_integer([:positive])}"),
        enrolled_at: DateTime.utc_now()
      },
      tenant: org.id,
      authorize?: false
    )
    |> then(fn changeset ->
      if id = opts[:id],
        do: Ash.Changeset.force_change_attribute(changeset, :id, id),
        else: changeset
    end)
    |> Ash.create!()
  end

  def membership(org, target, principal, capability, granter) do
    Targets.TargetMembership
    |> Ash.Changeset.for_create(
      :create,
      %{
        target_id: target.id,
        principal_id: principal.id,
        capability: capability,
        granted_by: granter.id
      },
      tenant: org.id,
      authorize?: false
    )
    |> Ash.create!()
  end

  @doc "A human principal as an actor: memberships loaded, as the session loader will."
  def human_actor(principal) do
    Ash.load!(principal, :memberships, authorize?: false, tenant: principal.org_id)
  end

  def api_key(org, principal, scopes, target_ids, opts \\ []) do
    Targets.ApiKey
    |> Ash.Changeset.for_create(
      :create,
      %{
        principal_id: principal.id,
        prefix: "k#{System.unique_integer([:positive])}",
        secret_sha256: :crypto.hash(:sha256, "synthetic"),
        scopes: scopes,
        target_ids: target_ids,
        expires_at: Keyword.get(opts, :expires_at)
      },
      tenant: org.id,
      authorize?: false
    )
    |> Ash.create!()
  end

  def system(role, org), do: Authz.System.new(role, org.id)

  def branch(org, target, owner, opts \\ []) do
    Branches.Branch
    |> Ash.Changeset.for_create(
      :create,
      %{
        target_id: target.id,
        principal_id: owner.id,
        overlay_id: Keyword.get(opts, :overlay_id, uuid()),
        base_snapshot_ref: "synthetic-snapshot",
        base_snapshot_fidelity: :TRUE_SNAPSHOT,
        base_snapshot_at: DateTime.utc_now(),
        idempotency_key: "idem-#{System.unique_integer([:positive])}",
        ttl_expires_at: DateTime.add(DateTime.utc_now(), 3600)
      },
      tenant: org.id,
      authorize?: false
    )
    |> then(fn changeset ->
      if id = opts[:id],
        do: Ash.Changeset.force_change_attribute(changeset, :id, id),
        else: changeset
    end)
    |> Ash.create!()
  end

  def changeset(org, branch) do
    Branches.Changeset
    |> Ash.Changeset.for_create(
      :create,
      %{branch_id: branch.id, target_id: branch.target_id, sequence: 1, trigger: "propose"},
      tenant: org.id,
      authorize?: false
    )
    |> Ash.create!()
  end

  def policy(org, target, creator) do
    Policies.Policy
    |> Ash.Changeset.for_create(
      :create,
      %{
        target_id: target.id,
        slug: "policy-#{System.unique_integer([:positive])}",
        created_by: creator.id
      },
      tenant: org.id,
      authorize?: false
    )
    |> Ash.create!()
  end

  def policy_version(org, policy, saver) do
    Policies.PolicyVersion
    |> Ash.Changeset.for_create(
      :create,
      %{
        policy_id: policy.id,
        version: 1,
        yaml: "name: synthetic\n",
        name: "synthetic",
        scope: %{},
        outcome: :hold,
        saved_by: saver.id
      },
      tenant: org.id,
      authorize?: false
    )
    |> Ash.create!()
  end

  def merge(org, branch, changeset) do
    Branches.Merge
    |> Ash.Changeset.for_create(
      :create,
      %{target_id: branch.target_id, branch_id: branch.id, changeset_id: changeset.id},
      tenant: org.id,
      authorize?: false
    )
    |> Ash.create!()
  end
end
