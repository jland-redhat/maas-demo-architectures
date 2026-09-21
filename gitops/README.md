# GitOps (OpenShift GitOps / Argo CD)

## Demo 08 Application

[`maas-demo08-application.yaml`](maas-demo08-application.yaml) syncs [`deploy/overlays/demo08`](../deploy/overlays/demo08/) from `main` onto the cluster (base simulators + Demo 08 default-tenant entitlements / external / streaming models).

Automated sync uses **prune** + **selfHeal** + **ServerSideApply**, so Git becomes the source of truth for those objects and overrides prior `oc apply` installs of the same names.

### One-time cluster setup

```bash
# Allow kustomize to load ../../../demos/... from the overlay
oc patch argocd openshift-gitops -n openshift-gitops --type=merge \
  -p '{"spec":{"kustomizeBuildOptions":"--load-restrictor LoadRestrictionsNone"}}'

# Lab: let the Application controller manage CRDs / take over existing resources
oc adm policy add-cluster-role-to-user cluster-admin \
  -z openshift-gitops-argocd-application-controller \
  -n openshift-gitops

oc apply -f gitops/maas-demo08-application.yaml
```

### Verify

```bash
oc -n openshift-gitops get applications.argoproj.io maas-demo08
# expect: Synced / Healthy
```

GitOps UI: `oc get route openshift-gitops-server -n openshift-gitops`

### Notes

- Partner / OIDC tenants are **not** in this Application (use their apply scripts).
- Local uncommitted repo changes are **not** synced until pushed to `main`.
