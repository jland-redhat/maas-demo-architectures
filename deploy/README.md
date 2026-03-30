# Deploying demo workloads (models + groups + entitlements)

This repo installs **simulated** inference workloads (same pattern as [upstream samples](https://github.com/opendatahub-io/models-as-a-service/tree/main/docs/samples/models/simulator)): five `LLMInferenceService` objects using `ghcr.io/llm-d/llm-d-inference-sim`, plus matching **`MaaSModelRef`**, OpenShift **`Group`**, and your chosen demo’s **`MaaSSubscription` / `MaaSAuthPolicy`**.

**Prerequisite:** [models-as-a-service](https://github.com/opendatahub-io/models-as-a-service/) is installed on OpenShift (Gateway `maas-default-gateway` in `openshift-ingress`, KServe, MaaS operator, etc.).

## One command (default: Demo 01 entitlements)

From the **repository root** (paths in `kustomization.yaml` stay inside the repo — no extra flags):

```bash
oc apply -k .
```

That applies `deploy/base` (namespaces, groups, five simulators, five `MaaSModelRef`) plus `demos/01-one-to-one/manifests/maas-entitlements.yaml`.

To switch the default bundle, edit the root `kustomization.yaml` and change the second `resources` entry to another demo path.

## One command per overlay (any demo)

`oc kustomize` blocks references **outside** the overlay directory unless you relax the loader. Use **`LoadRestrictionsNone`** and pipe to apply:

```bash
oc kustomize --load-restrictor LoadRestrictionsNone deploy/overlays/demo02 | oc apply -f -
```

Replace `demo02` with `demo01` … `demo06` or use `models-only` (no `MaaS*` entitlements — only base).

**Models-only** (no subscriptions/policies):

```bash
oc kustomize deploy/overlays/models-only | oc apply -f -
```

(`models-only` does not need `LoadRestrictionsNone` because all resources live under that directory.)

## What gets installed

| Layer | Location |
|--------|----------|
| Namespaces `llm`, `models-as-a-service` | `deploy/base/namespaces.yaml` |
| OpenShift `Group` objects | `deploy/base/groups.yaml` (keep in sync with `shared/identity/common-openshift-groups.yaml`) |
| Five `LLMInferenceService` simulators | `deploy/base/inference/simulators.yaml` |
| Five `MaaSModelRef` | `deploy/base/maas-modelrefs/modelrefs.yaml` |
| Entitlements | `demos/<demo>/manifests/maas-entitlements.yaml` |

## Demo token limits (`tokenRateLimits`)

Manifests use **small numbers** so live demos stay easy: roughly **50–2000 tokens per minute** per model (same `1m` window everywhere). Tight caps (**50**) mark “expensive” or lowest-tier routes; **2000** is the lab ceiling. Raise limits in your fork for production-like load tests.

## Lab users and passwords

Groups reference users **`alice`**, **`bob`**, **`chloe`**, **`dana`**. They must exist in your IdP. **Who is in which group** (and what each demo means for them) is documented per pattern under [demos/](../demos/README.md), with a **full** membership matrix in [demos/README.md — Full lab identity](../demos/README.md#full-lab-identity-openshift-groups). For an **HTPasswd** IdP, generate a file with [shared/identity/htpasswd-sample-users.sh](../shared/identity/htpasswd-sample-users.sh), create the OAuth secret, and add the IdP to the cluster (see OpenShift **Identity Providers** documentation).

## Log in as a specific user (real credentials)

```bash
oc login --token=<your-token>  # or user/password against API URL
# HTPasswd example:
oc login -u alice -p alicepass https://api.<cluster>:6443
```

## Can I get a token for another user?

**Not as an administrator impersonating them**, in the sense of minting that person’s **OAuth access token** without their participation. OpenShift does not offer “assume user and receive their long‑lived bearer token” the way some cloud IAM systems do—that would break accountability.

What you can do instead:

| Need | Approach |
|------|----------|
| **A real user token** for testing | Have that user **`oc login`** (password, web OAuth, or `oc login --token` after they obtain a token from the console). |
| **Short‑lived proof of identity** | User runs **`oc whoami -t`** after logging in; they hand you the token only in a controlled lab (tokens are secrets). |
| **API calls as another user without their password** | **`--as` / `--as-group`** impersonation (cluster admins); not a token, but each request is evaluated as that user. |
| **Non‑human callers** | **`ServiceAccount`** tokens: `oc create token -n <ns> <sa-name>` (Kubernetes 1.24+ style) or bound tokens per cluster docs. |

So: **you cannot safely “fetch Alice’s token” without Alice authenticating** (or without a pre‑provisioned credential you are allowed to use). Use **`oc login` as Alice** in a lab, or **impersonation** for RBAC checks.

## Impersonate a user for quick API / RBAC checks (cluster admins)

If your kubeconfig user may **impersonate** (typically **cluster-admin**), you can run `oc` / API calls **as** another user and **as** their groups (JWT-style groups for authorization checks):

```bash
# Resolve effective identity (example: alice in the Granite line-item group)
oc whoami --as=alice --as-group=maas-demo-line-granite --as-group=system:authenticated

# Example: list namespaced resources visible under that identity
oc get maasmodelref -n llm --as=alice --as-group=maas-demo-line-granite --as-group=system:authenticated
```

Repeat `--as-group` for every group the user should belong to for that request. This does **not** create a full OAuth session or MaaS API key; it is useful for **kubectl-level** RBAC debugging. MaaS gateway auth still follows your real IdP and API key flows.

## Verify workloads

```bash
oc get llminferenceservice -n llm
oc get maasmodelref -n llm
oc get maassubscription,maasauthpolicy -n models-as-a-service
```

Wait until `MaaSModelRef` **phase** is `Ready` and pods in `llm` are running before calling the MaaS API.
