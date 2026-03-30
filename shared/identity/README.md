# Identity and groups for ODH MaaS demos

`MaaSAuthPolicy.spec.subjects` and `MaaSSubscription.spec.owner` use **Kubernetes user and group names** from your IdP (OAuth on OpenShift). They must match what appears in the JWT or API authentication flow the MaaS gateway uses.

## Common groups (this repo)

| Group | Typical use in demos |
|--------|----------------------|
| `maas-demo-admins` | Operators (`dana`) |
| `maas-demo-research` | R&D (`alice`) |
| `maas-demo-apps` | App teams (`alice`, `bob`) |
| `maas-demo-restricted` | Tight access (`chloe`) |
| `maas-demo-org` | Broad org membership (`alice`, `bob`, `chloe`) for [Demo 03](../demos/03-org-catalog/) |

Apply `common-openshift-groups.yaml` after users exist in your IdP.

## Upstream references

- Keycloak + group sync for MaaS: [docs/samples/install/keycloak](https://github.com/opendatahub-io/models-as-a-service/tree/main/docs/samples/install/keycloak)
- Self-service access: [user-guide/self-service-model-access](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/user-guide/self-service-model-access.md)

## htpasswd helper

For a lab-only HTPasswd IdP, generate a password file with `htpasswd-sample-users.sh` (Podman-first; Docker noted in the script). **Production** deployments should use a real enterprise IdP and PostgreSQL-backed API keys per upstream prerequisites.
