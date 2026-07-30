# Identity and groups for ODH MaaS demos

`MaaSAuthPolicy.spec.subjects` and `MaaSSubscription.spec.owner` use **Kubernetes user and group names** from your IdP (OAuth on OpenShift). They must match what appears in the JWT or API authentication flow the MaaS gateway uses.

## Lab users (people, not just group names)

| User | Role in stories | Notes |
|------|-----------------|--------|
| **alice** | Research + often apps; Demo 01: Granite + GPT line items | Can belong to **multiple** groups to show overlap. |
| **bob** | App developer; Demo 01: Llama line item | Usually **`maas-demo-apps`**. |
| **chloe** | Restricted / low-trust; Demo 01: Mistral line item | **`maas-demo-restricted`**. |
| **dana** | Operator; **`maas-demo-admins`**; Demo 01: Qwen + shared GPT | Full-catalog and break-glass demos. |

The full membership table lives in [demos/README.md — Full lab identity](../../demos/README.md#full-lab-identity-openshift-groups). Each demo README also lists **OpenShift `Group` membership** for that scenario.

## Common groups (this repo)

| Group | Typical use in demos |
|--------|----------------------|
| **`maas-admin`** | **Presenter break-glass** — on every subscription + auth policy; defaults include common lab admins (`htpasswd-cluster-admin-user`, `kubeadmin`, `cluster-admin`, `admin`) |
| `maas-demo-admins` | Story persona operators (`dana`) — Demo 03 admin slice |
| `maas-demo-research` | R&D (`alice`) |
| `maas-demo-apps` | App teams (`alice`, `bob`) |
| `maas-demo-restricted` | Tight access (`chloe`) |
| `maas-demo-org` | Broad org membership (`alice`, `bob`, `chloe`) for [Demo 03](../../demos/03-org-catalog/) |
| `maas-demo-line-*` | One group per **subscription+policy pair** in [Demo 01](../../demos/01-one-to-one/) (here one model per pair) |

```bash
oc adm groups add-users maas-admin $(oc whoami)
```

Apply `common-openshift-groups.yaml` after users exist in your IdP.

**Kustomize:** [deploy/base/groups.yaml](../deploy/base/groups.yaml) is a copy of this file (OpenShift’s loader requires it under `deploy/base/`). Update **both** when you change group membership.

**Per-demo subset:** each folder under [demos/](../demos/) includes `manifests/required-groups.yaml` with only the `Group` objects that demo’s subscriptions and policies need—useful when you apply entitlements without the full [deploy](../deploy/README.md) bundle.

## Upstream references

- Keycloak + group sync for MaaS: [docs/samples/install/keycloak](https://github.com/opendatahub-io/models-as-a-service/tree/main/docs/samples/install/keycloak)
- Self-service access: [user-guide/self-service-model-access](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/user-guide/self-service-model-access.md)

## htpasswd helper

For a lab-only HTPasswd IdP, generate a password file with `htpasswd-sample-users.sh` (Podman-first; Docker noted in the script). **Production** deployments should use a real enterprise IdP and PostgreSQL-backed API keys per upstream prerequisites.
