# Odoo Helm chart

Runs Odoo 20 on Kubernetes, either as disposable review apps or as persistent instances
on a [CloudNativePG](https://cloudnative-pg.io) cluster. Updates are safe by design: the
chart stops Odoo, takes a cold restore point, updates the modules, then restarts Odoo. A
failed update never serves a half-migrated database.

- [Features](#features)
- [Requirements](#requirements)
- [Install](#install)
- [Update sequence](#update-sequence)
- [Restore points](#restore-points)
- [Values](#values)
- [Operations](docs/operations.md): restoring, rolling back, recovering from a disaster,
  copying production

## Features

- **Two modes.** `ephemeral: true` is a review app: the chart creates its own PostgreSQL
  and Secrets, and every new image starts from an empty database with demo data.
  `ephemeral: false` (default) is a persistent instance whose data is kept, on a
  CloudNativePG cluster installed separately.
- **Updates in Helm hooks.** `helm upgrade` stops Odoo, takes the restore point, updates
  the modules with [`click-odoo-update`](https://github.com/acsone/click-odoo-contrib)
  (changed modules only), then starts the new image. Nothing can start Odoo between the
  snapshot and the module update, even a `helm upgrade` run by hand.
- **Cold restore points.** A CloudNativePG volume snapshot backup of the database, taken
  with Odoo stopped, and a snapshot of the filestore volume. Old points are purged
  automatically.
- **Configuration from values.** `odoo.conf` is generated from `odoo.config`, without
  any secret; passwords come from Kubernetes Secrets as environment variables, which
  Odoo 20 reads natively.
- **Image by digest or tag.** The digest is recommended: what runs is what was tested,
  and restore points record that exact image.
- **Hardened pods.** Non-root, read-only root filesystem, no capabilities, no service
  account token in the Odoo pods; NetworkPolicies.
- **Gateway API.** One `HTTPRoute` for HTTP and, with `workers > 0`, the websocket
  (`/websocket`), and optionally [Mailpit](https://mailpit.axllent.org) to catch
  outgoing mail.

## Requirements

The chart installs no cluster component. It needs:

| Requirement                                                                                                            | Used for                | Tested with                                    |
| ---------------------------------------------------------------------------------------------------------------------- | ----------------------- | ---------------------------------------------- |
| Kubernetes and Helm 4                                                                                                  | everything              | Kubernetes 1.37, Helm 4.3                      |
| An Odoo 20 image following the [image contract](#image-contract)                                                       | Odoo and its Jobs       |                                                |
| A Gateway API implementation (`route.parentRefs`)                                                                      | public access, optional | Gateway API 1.6                                |
| A storage class for the filestore volume                                                                               | `odoo.persistence`      |                                                |
| **Persistent instances only:**                                                                                         |                         |                                                |
| CloudNativePG, with a database cluster [configured for the chart](#database-of-a-persistent-instance)                  | the database            | CloudNativePG 1.30, `cnpg/cluster` chart 0.9.0 |
| The Barman Cloud plugin and an S3-compatible object store, for the nightly backups and the write-ahead log archive     | disaster recovery       | plugin-barman-cloud 0.15                       |
| A recurring backup of the filestore volume outside the cluster, e.g. a Longhorn `RecurringJob` of task `backup`        | disaster recovery       | Longhorn 1.12                                  |
| A CSI driver with volume snapshots, the snapshot controller, and a `VolumeSnapshotClass` with `deletionPolicy: Delete` | restore points          | csi-driver-host-path 1.18                      |
| An [application Secret](#application-secret) (`secrets.existingSecret`)                                                | Odoo passwords          |                                                |

Several Odoo instances (`odoo.replicas > 1`) need a shared filestore: a `ReadWriteMany`
volume, or no volume with the filestore on S3.

### Database of a persistent instance

The chart does not install the database: it connects to a CloudNativePG cluster through
`database.external`, installed and operated by you (for instance with the `cnpg/cluster`
chart). The cluster must provide:

- **A role for Odoo**, with `LOGIN` and `CREATEDB` (the first installation creates the
  database `database.name`), not superuser. Its credentials are in a
  `kubernetes.io/basic-auth` Secret (`username`, `password`),
  `database.external.secret`. Declare the role in the cluster (`spec.managed.roles`,
  with `passwordSecret`) rather than at bootstrap only: a cluster restored from a
  restore point then gets the same role and password.
- **The right to name restore points**: `EXECUTE` on `pg_create_restore_point(text)` for
  that role, granted in the database `postgres` (for instance in
  `bootstrap.initdb.postInitSQL`).
- **Cold volume snapshots**: `spec.backup.volumeSnapshot` with
  `className: <VolumeSnapshotClass>`, `online: false` and
  `snapshotOwnerReference: backup`, on a storage class that supports snapshots. The
  `cnpg/cluster` chart cannot set this section yet
  ([cloudnative-pg/charts#900](https://github.com/cloudnative-pg/charts/issues/900)):
  patch the `Cluster` after each installation of the database, a restored one included;
  its `helm upgrade` keeps the patch. Without it, an update of Odoo fails before
  stopping Odoo.
- **A stable `Service`**, `database.external.host`, created outside any Helm release,
  port 5432, selecting `cnpg.io/cluster: <active cluster>` and
  `cnpg.io/instanceRole: primary`. The chart reads the active cluster from this
  selector; a restoration switches it to the restored cluster.

Also recommended: write-ahead log archiving and scheduled backups to object storage
(Barman Cloud plugin), the only copy that survives the loss of the cluster, one folder
per cluster. In a namespace that denies traffic by default, allow the pods of the
release (`app.kubernetes.io/name: odoo`, `app.kubernetes.io/instance: <release>`) to
reach the database on port 5432, along with the CloudNativePG operator.

### Application Secret

`secrets.existingSecret` names a Secret of the namespace with the keys:

- `admin-passwd`: the master password (database manager, `odoo db` commands);
- `admin-user-password`: the password of the user `admin`, read when the first
  installation creates the database, and by an update with `neutralize=true`;
- `smtp-password` (optional): the password of `odoo.config.options.smtp_user`.

Odoo reads them as environment variables: restart it after a change
(`kubectl rollout restart deployment/<release>`). A private image also needs a
`docker-registry` Secret, named in `image.pullSecrets`.

### Image contract

The defaults follow the official `odoo` image: an image built `FROM odoo:20.0` with
`click-odoo-contrib` installed works as is.

- **User**: the chart runs the image as a non-root user with a read-only root
  filesystem. `podSecurityContext` sets the user, uid 100 and gid 101 by default (the
  user `odoo` of the official image); set it to the user of your image, which must be
  able to read the files of the image.
- **Addons**: `odoo.config.options.addons_path`, `/mnt/extra-addons` by default.
- **Data directory**: `/var/lib/odoo`, the volume of the chart (imposed).
- **Entrypoint**: the Odoo pods run the image's entrypoint and command (Odoo), the Jobs
  its entrypoint with `odoo …` or `click-odoo-update` as arguments. It must run them
  with the configuration of the chart (`$ODOO_RC`, `PG*` variables), as the official
  `/entrypoint.sh` does.
- **Commands** in the `PATH`: `odoo` (Odoo 20 command line, with `odoo db init`),
  `click-odoo-update`, and `psql`, used to wait for PostgreSQL and to name the restore
  point in the write-ahead log.

### Image reference

Set `image.digest`, `image.tag`, or both; the Odoo containers run
`repository[:tag][@digest]`. With a digest, the digest decides what runs and the tag is
only informative: it is also set as the label `app.kubernetes.io/version` of the Odoo
pods, so `kubectl get pods -L app.kubernetes.io/version` shows the version that runs.

**Prefer the digest** for persistent instances. A tag can be pushed again with another
image, and the chart then cannot tell:

- the restore point records the reference, not the image: a rollback after a restore
  (`helm rollback`) may start a newer image than the one the database was saved with;
- a new image behind the same tag changes nothing in the rendered release, and the nodes
  keep the image they have already pulled (`IfNotPresent`, the Kubernetes default): only
  pods started afterwards with `image.pullPolicy: Always` run it, and the Jobs of one
  update may not all run the same image;
- a review app resets its database when the reference changes, not when the image behind
  the same tag changes.

A tag that is never pushed twice (a release version) avoids all of this.

## Install

A review app, for a quick look (the chart creates the database):

```sh
helm upgrade --install pr-42 oci://ghcr.io/skilldron/charts/odoo --version <version> -n odoo-review \
  --set ephemeral=true \
  --set image.repository=ghcr.io/acme/odoo/builds \
  --set image.tag=<tag> \
  --set 'route.parentRefs[0].name=gateway' --set route.reviewDomain=review.example.com
kubectl -n odoo-review rollout status deploy/pr-42
```

The chart is published as an OCI artifact on GHCR; pin its `--version` (the versions are
listed on the [releases](https://github.com/Skilldron/odoo-helm-chart/releases)). The
review app above expects a Gateway named `gateway` in its namespace; set
`route.parentRefs[0].namespace` otherwise.

A persistent instance, in its own namespace:

1. Prepare the [database](#database-of-a-persistent-instance), the `VolumeSnapshotClass`
   (`deletionPolicy: Delete`) and the [application Secret](#application-secret).
2. Write the values of the instance. The minimum:

   ```yaml
   environment: production
   image:
     repository: ghcr.io/acme/odoo
     pullSecrets: [ghcr]
   odoo:
     modules: [sale_management, acme_custom]
   secrets:
     existingSecret: odoo-app
   database:
     external: {host: odoo-db, secret: odoo-db-credentials}
   restorePoints:
     volumeSnapshotClass: csi-snapclass
   route:
     parentRefs: [{name: gateway, namespace: gateway-system}]
     host: odoo.example.com
   ```

3. Install Odoo. The first installation creates the database, so do not use `--wait`:
   the Odoo pods wait for the database, which a `post-install` Job creates.

   ```sh
   helm upgrade --install odoo oci://ghcr.io/skilldron/charts/odoo --version <version> -n odoo-prod -f values.yaml \
     --set image.digest=sha256:<digest>
   kubectl -n odoo-prod rollout status deploy/odoo --timeout=30m
   ```

4. Update with `--wait`, so that the release only succeeds once Odoo serves the new
   version:

   ```sh
   helm upgrade odoo oci://ghcr.io/skilldron/charts/odoo --version <version> -n odoo-prod -f values.yaml \
     --set image.digest=sha256:<new digest> --wait --timeout 60m
   ```

## Update sequence

| Step | Hook           | What happens                                                                                                                                |
| ---- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| 1    | `pre-upgrade`  | Job `stop-snapshot`: Odoo scaled to 0, restore point named in the write-ahead log, cold `Backup` of the database, snapshot of the filestore |
| 2    | `pre-upgrade`  | Job `migrate`: `odoo -i` installs the listed modules that are missing, then `click-odoo-update` updates the changed ones                    |
| 3    | —              | Helm applies the Deployments: new image, Odoo starts                                                                                        |
| 4    | `post-upgrade` | Job `validate`: the restore point becomes `validated`, old points are purged                                                                |

The first installation and review apps run `migrate` in `post-install` (and
`post-upgrade` for review apps): it creates the database with `odoo db init`, then
installs the modules. The Odoo pods wait for it in an init container.

**When an update fails**, Odoo stays stopped and the restore point stays `pending`.
Retrying the update reuses that point, if it is complete, instead of taking a new one;
an incomplete point (failed snapshot) is replaced, and deleted by the next successful
update. To go back, restore the point
([operations](docs/operations.md#restore-after-a-failed-update)): the module update
commits module by module, so the previous image cannot run on the half-migrated
database.

## Restore points

A restore point is a CloudNativePG `Backup` (method `volumeSnapshot`, offline), named
`<cluster>-preupgrade-r<revision>`, with labels under `labelPrefix`:

| Label                    | Values                                                                                             |
| ------------------------ | -------------------------------------------------------------------------------------------------- |
| `<prefix>/backup-type`   | `pre-upgrade`                                                                                      |
| `<prefix>/upgrade-state` | `pending` (update not validated yet), `validated` (update succeeded), `restored` (used to restore) |

The filestore snapshot is named in the annotation `<prefix>/filestore` and owned by the
`Backup`: deleting the `Backup` deletes the whole point. After each successful update,
`validate` keeps the `restorePoints.keep` newest `validated` and `restored` points and
deletes the others. It never deletes a complete `pending` point, and a purge error never
fails the update.

The database cluster must allow offline volume snapshots, which the `cnpg/cluster` chart
cannot set yet:

```sh
kubectl -n odoo-prod patch cluster odoo-db --type merge -p \
  '{"spec":{"backup":{"volumeSnapshot":{"className":"<VolumeSnapshotClass>","online":false,"snapshotOwnerReference":"backup"}}}}'
```

## Values

| Value                                                        | Default                | Description                                                                                                                                                                                                                                                                                                                                                                                                 |
| ------------------------------------------------------------ | ---------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ephemeral`                                                  | `false`                | Disposable review app: own PostgreSQL and Secrets, demo data, reset with every image, no restore points                                                                                                                                                                                                                                                                                                     |
| `neutralize`                                                 | `false`                | Neutralize the database (`odoo neutralize`) before the module update, then set the password of `admin` and, with Mailpit, send mail to it; only on the command line, for the update that follows a copy of production data                                                                                                                                                                                  |
| `environment`                                                | `""`                   | Name of the environment, set as a label                                                                                                                                                                                                                                                                                                                                                                     |
| `project`                                                    | `odoo`                 | Prefix of the review app hosts                                                                                                                                                                                                                                                                                                                                                                              |
| `labelPrefix`                                                | `odoo.haroldd.dev`     | Prefix of the chart's labels and annotations. Changing it hides the existing restore points from the chart                                                                                                                                                                                                                                                                                                  |
| `image.repository`                                           |                        | Odoo image                                                                                                                                                                                                                                                                                                                                                                                                  |
| `image.digest`, `image.tag`                                  | `""`                   | [Image reference](#image-reference): the digest (`sha256:…`, recommended), the tag, or both; the digest takes precedence                                                                                                                                                                                                                                                                                    |
| `image.pullPolicy`                                           | `""`                   | `Always`, `IfNotPresent` or `Never`; empty: Kubernetes default                                                                                                                                                                                                                                                                                                                                              |
| `image.pullSecrets`                                          | `[]`                   | Registry Secrets                                                                                                                                                                                                                                                                                                                                                                                            |
| `podLabels`, `podAnnotations`                                | `{}`                   | Labels and annotations added to the Odoo pods; the chart's own keys keep their value                                                                                                                                                                                                                                                                                                                        |
| `podSecurityContext.runAsUser`, `.runAsGroup`, `.fsGroup`    | `100`, `101`, `101`    | User and group of the Odoo containers, those of the image; `fsGroup` makes the volumes writable. `null` omits the field (OpenShift, numeric `USER`)                                                                                                                                                                                                                                                         |
| `odoo.replicas`                                              | `1`                    | Odoo instances                                                                                                                                                                                                                                                                                                                                                                                              |
| `odoo.modules`                                               | `[]`                   | Modules installed by the `migrate` Job; `base` when empty                                                                                                                                                                                                                                                                                                                                                   |
| `odoo.config.<section>.<option>`                             | see `values.yaml`      | `odoo.conf`. The chart sets `data_dir` and `http_interface`; no option name may contain `passw` (password), `secret` or `token`                                                                                                                                                                                                                                                                             |
| `odoo.persistence.*`                                         | `ReadWriteOnce`, `5Gi` | Filestore volume; `enabled: false` for a filestore on S3; `existingClaim` to use a restored volume                                                                                                                                                                                                                                                                                                          |
| `secrets.existingSecret`                                     |                        | Application Secret: `admin-passwd`, `admin-user-password` (first installation, `neutralize`), optional `smtp-password`. Required unless `ephemeral`                                                                                                                                                                                                                                                         |
| `secrets.env`                                                | `[]`                   | More environment variables from Secrets: `{name, secret, key}`; `optional: true` starts Odoo without the Secret (a `$(NAME)` reference to it then stays literal)                                                                                                                                                                                                                                            |
| `odoo.env`                                                   | `{}`                   | More environment variables, in clear, strings: `{NAME: value}`, merged across values files; rendered after the chart's variables (`ODOO_IMAGE_TAG`: `image.tag`, only when set) and `secrets.env`, a value can reference them as `$(NAME)` (an unset one stays literal), not another `odoo.env` entry. A key set in a values file cannot be removed by a later one. No secret, no variable set by the chart |
| `database.name`                                              | `odoo`                 | Odoo database                                                                                                                                                                                                                                                                                                                                                                                               |
| `database.external.host`, `.port`, `.secret`                 |                        | Stable Service of the database cluster, and the Secret with `username` and `password`. Required unless `ephemeral`                                                                                                                                                                                                                                                                                          |
| `database.ephemeral.*`                                       | `postgres:18`, `2Gi`   | PostgreSQL of a review app                                                                                                                                                                                                                                                                                                                                                                                  |
| `restorePoints.keep`                                         | `3`                    | Restore points kept after an update                                                                                                                                                                                                                                                                                                                                                                         |
| `restorePoints.volumeSnapshotClass`                          |                        | Class of the filestore snapshot (`deletionPolicy: Delete`)                                                                                                                                                                                                                                                                                                                                                  |
| `restorePoints.timeoutSeconds`                               | `900`                  | Delay for the snapshots to be ready                                                                                                                                                                                                                                                                                                                                                                         |
| `jobs.migrate.activeDeadlineSeconds`                         | `1800`                 | Maximum duration of the module update                                                                                                                                                                                                                                                                                                                                                                       |
| `mailpit.enabled`                                            | `false`                | Catch outgoing mail in Mailpit                                                                                                                                                                                                                                                                                                                                                                              |
| `route.parentRefs`, `.host`, `.mailpitHost`, `.reviewDomain` |                        | `HTTPRoute`; review apps are served at `<project>-<release>.<reviewDomain>`                                                                                                                                                                                                                                                                                                                                 |
| `networkPolicy.ingressFrom`                                  | `[]`                   | Sources allowed to reach Odoo (the Gateway); empty: any                                                                                                                                                                                                                                                                                                                                                     |

`values.schema.json` and the templates refuse inconsistent values: an image by tag, a
password in `odoo.conf`, several instances on a `ReadWriteOnce` volume, a missing
Secret…

## Development

```sh
ci/lint.sh   # helm lint, kubeconform and the checks of the rendered manifests
```

`ci/lint.sh` needs `helm` 4 and `kubeconform`; it renders the chart with the values of
`tests/values` and checks the generated `odoo.conf`, the hooks of each case, the account
of the hooks, the filestore modes and the refused values. The same checks run on every
pull request.

A release is a tag `vX.Y.Z` equal to `version` in `charts/odoo/Chart.yaml`: the release
workflow packages the chart and pushes it to `oci://ghcr.io/skilldron/charts/odoo`.

## License

[Apache License 2.0](LICENSE).
