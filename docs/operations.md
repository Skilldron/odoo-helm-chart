# Operations

Procedures for persistent instances (`ephemeral: false`). `<chart>` is the chart with
its version (`oci://ghcr.io/skilldron/charts/odoo --version <version>`). The commands
use the release `odoo` in the namespace `odoo-prod`, the database cluster `odoo-db`
installed with the `cnpg/cluster` chart, and the label prefix `odoo.haroldd.dev`. Adapt
the names.

```sh
ns=odoo-prod
p=odoo.haroldd.dev
```

- [List the restore points](#list-the-restore-points)
- [Restore after a failed update](#restore-after-a-failed-update)
- [Roll back to an earlier restore point](#roll-back-to-an-earlier-restore-point)
- [Restore the filestore](#restore-the-filestore)
- [Validate an orphan restore point](#validate-an-orphan-restore-point)
- [After a restoration](#after-a-restoration)
- [Investigate a failed hook Job](#investigate-a-failed-hook-job)
- [Recover from a disaster](#recover-from-a-disaster)
- [Copy production into another instance](#copy-production-into-another-instance)

## List the restore points

```sh
kubectl -n $ns get backups.postgresql.cnpg.io -l $p/backup-type=pre-upgrade \
  -L $p/upgrade-state --sort-by=.metadata.creationTimestamp
```

A point is **complete** when its `Backup` is `completed` and, with a filestore volume,
the snapshot named in its annotation `$p/filestore` is `readyToUse`.

## Restore after a failed update

After a failed update, Odoo is stopped and the restore point of the update is `pending`.
The database may be half-migrated: restore it, then roll the release back. The
restoration creates a **new** database cluster and keeps the old one for analysis.

1. Find the complete `pending` point, `odoo-db-preupgrade-r<N>`: `N` is the Helm
   revision of the failed update.

   ```sh
   kubectl -n $ns get backups.postgresql.cnpg.io -l $p/upgrade-state=pending
   ```

   No complete `pending` point means the update failed before touching the database: go
   to step 5. An incomplete point (failed snapshot) cannot be restored; it is deleted by
   the next successful update, or by hand.

2. Create the cluster `odoo-db-r<N>` from the point: a CloudNativePG recovery from the
   `Backup` `odoo-db-preupgrade-r<N>` (`bootstrap.recovery.backup`), with the same
   database, owner and declared role as the current cluster, so that Odoo connects with
   the same Secret. With the `cnpg/cluster` chart, reuse the values and the chart
   version of the current database release (`helm list -n $ns`):

   ```sh
   helm get values odoo-db -n $ns -o yaml >db-values.yaml
   helm install odoo-db-r<N> cluster --repo https://cloudnative-pg.github.io/charts \
     --version <chart version of odoo-db> -n $ns -f db-values.yaml \
     --set fullnameOverride=odoo-db-r<N> --set mode=recovery --set cluster.instances=1 \
     --set recovery.method=backup --set recovery.backupName=odoo-db-preupgrade-r<N> \
     --set recovery.database=<database of odoo-db> --set recovery.owner=<owner of odoo-db>
   kubectl -n $ns wait cluster/odoo-db-r<N> --for=condition=Ready --timeout=30m
   ```

3. Allow restore points on the new cluster, with the same settings as the old one:

   ```sh
   kubectl -n $ns patch cluster odoo-db-r<N> --type merge -p \
     "$(kubectl -n $ns get cluster odoo-db -o json |
       jq -c '{spec: {backup: {volumeSnapshot: .spec.backup.volumeSnapshot}}}')"
   ```

4. Switch the stable Service to the new cluster, and mark the point as used:

   ```sh
   kubectl -n $ns patch service odoo-db \
     -p '{"spec":{"selector":{"cnpg.io/cluster":"odoo-db-r<N>"}}}'
   kubectl -n $ns label backups.postgresql.cnpg.io odoo-db-preupgrade-r<N> \
     $p/upgrade-state=restored --overwrite
   ```

5. Roll the release back to the last revision deployed before `N`. The update hooks do
   not run on a rollback: Odoo restarts on the previous image (the same image if it was
   given by digest; see [Image reference](../README.md#image-reference) for a tag).

   ```sh
   helm history odoo -n $ns
   helm rollback odoo <revision> -n $ns --wait --timeout 15m
   ```

The database is back to the moment Odoo was stopped for the update: nothing entered by
users is lost. The filestore is not restored: it is content-addressed, so a restored
database finds its files, and the files added by the failed update are unused.

## Roll back to an earlier restore point

To go back to an older version, stop Odoo, then follow the same procedure from step 2
with a `validated` point `odoo-db-preupgrade-r<N>`: roll the release back to the last
revision deployed before that `N`.

```sh
kubectl -n $ns scale deployment odoo --replicas=0
```

Everything entered since that point is lost.

## Restore the filestore

Each point with a filestore volume has a `VolumeSnapshot`, named in the annotation
`$p/filestore` of its `Backup`. To bring the files back too, create a volume from it and
point the release at it:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: odoo-data-restored
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 5Gi}}
  dataSource:
    apiGroup: snapshot.storage.k8s.io
    kind: VolumeSnapshot
    name: <snapshot of the point>
```

```sh
helm upgrade odoo <chart> -n $ns --reuse-values \
  --set odoo.persistence.existingClaim=odoo-data-restored --wait
```

## Validate an orphan restore point

If an update succeeded but its `validate` hook failed, the point stays `pending` while
Odoo already serves the new version. The next update refuses to start, since restoring
that point would lose everything entered since. Check that Odoo works, then:

```sh
kubectl -n $ns label backups.postgresql.cnpg.io <point> $p/upgrade-state=validated --overwrite
```

## After a restoration

- [Analyse the old cluster](#analyse-the-old-cluster) if needed, then uninstall it:
  `helm uninstall odoo-db -n $ns`. The stable Service belongs to no release and stays in
  place. The `cnpg/cluster` chart creates the `ObjectStore` as a hook, which
  `helm uninstall` keeps: delete it too,
  `kubectl -n $ns delete objectstores.barmancloud.cnpg.io odoo-db-backups`. Its backups
  stay in the object storage.
- The restored cluster has one instance. Scale it with the same chart reference as its
  installation:
  `helm upgrade odoo-db-r<N> cluster --repo https://cloudnative-pg.github.io/charts --version <version> -n $ns --reuse-values --set cluster.instances=3`.
- The restore points of the old cluster stay listed and usable until the retention
  purges them.

### Analyse the old cluster

The old cluster holds the database as the failed update left it. It keeps its own
Services (`odoo-db-rw`, `odoo-db-r`): only the stable Service moved to the restored
cluster. Odoo's database is `database.name` (`odoo` by default).

1. Read the logs of the failed Job first
   ([Investigate a failed hook Job](#investigate-a-failed-hook-job)): the traceback is
   usually enough.
2. Query the database, as `postgres` over the local socket of the instance:

   ```sh
   kubectl -n $ns exec -it odoo-db-1 -c postgres -- psql -d odoo
   ```

   Run the same queries on the restored cluster (`odoo-db-r<N>-1`) to compare, for
   instance the state of the updated modules:
   `select name, latest_version, state from ir_module_module where name = '<module>';`.
   For a desktop client, forward the port of the old cluster
   (`kubectl -n $ns port-forward svc/odoo-db-rw 5433:5432`) and connect with the
   credentials of the database Secret.

3. Reproduce the failure in a development environment, from a dump:

   ```sh
   kubectl -n $ns exec odoo-db-1 -c postgres -- pg_dump -Fc -d odoo >failed.dump
   ```

   Restore it with `pg_restore`, then run the update with the code of the release and a
   debugger. The dump holds the data of the instance: protect it like the instance, and
   delete it after use. It does not contain the filestore, which a module update seldom
   needs.

Odoo updates the modules in one transaction: a failed update is rolled back, and the old
cluster then matches the restore point, so a dump of the restored cluster reproduces the
failure as well. The old cluster differs when a migration script commits along the way
(`cr.commit()`) and leaves part of its changes.

## Investigate a failed hook Job

The hook Jobs (`<release>-stop-snapshot`, `<release>-migrate`, `<release>-validate`) are
kept until the next update:

```sh
kubectl -n $ns get jobs -l app.kubernetes.io/instance=odoo
kubectl -n $ns logs job/odoo-migrate --all-containers --ignore-errors
```

`migrate` runs its steps as successive containers (`db-init`, `neutralize` and `adapt`
when asked, `install`, `update`): the failing container names the failing step.

## Recover from a disaster

Restore points do not survive the loss of the namespace or of the cluster: volume
snapshots live in the same cluster. The nightly backups and the write-ahead log,
archived to object storage by the Barman Cloud plugin, remain. Recover them into a new
cluster (`bootstrap.recovery` from the object store, archiving into a new folder: Barman
refuses a non-empty one). Each update names a restore point `odoo-db-preupgrade-r<N>` in
the write-ahead log just before its snapshot: use it as `recoveryTarget.targetName` to
recover the database as it was before that update. See CloudNativePG
[Recovery](https://cloudnative-pg.io/documentation/current/recovery/) and the
[Barman Cloud plugin](https://cloudnative-pg.io/plugin-barman-cloud/) documentation.

Then recreate the stable Service, the Secrets and the release as for an installation,
and restore the filestore from its own backup: the S3 bucket, or the last backup of the
volume outside the cluster. The chart backs up the database only: install a recurring
job that backs the filestore volume up outside the cluster with the instance, for
example a Longhorn `RecurringJob` of task `backup`. A backup taken by a `VolumeSnapshot`
whose class deletes its content goes away with the namespace. Longhorn lists the backups
of its backup target (`kubectl -n longhorn-system get backups.longhorn.io`): restore one
as in [Copy the filestore volume](#copy-the-filestore-volume), then install the release
with `odoo.persistence.existingClaim`. The filestore is as recent as its last backup,
the database as the last archived write-ahead log: files added in between are missing.

## Copy production into another instance

To give a staging or preproduction instance a copy of the production data, with `ns` the
target namespace and `prod` that of production:

```sh
ns=odoo-staging
prod=odoo-prod
```

1. Recover the latest production backup from object storage into a new database cluster
   of the target namespace, as for a disaster, with read-only credentials to the
   production bucket and the target's own backup folder.
2. Bring the production filestore into the target namespace. With S3, copy the
   production bucket into the target's own bucket. With a volume, restore a backup of
   the production volume taken to remote storage: a volume snapshot does not cross
   namespaces or clusters. See [Copy the filestore volume](#copy-the-filestore-volume)
   for Longhorn.
3. Stop Odoo, so that it does not connect to the copy before it is neutralized:

   ```sh
   kubectl -n $ns scale deployment odoo --replicas=0
   ```

   With a volume, then copy `filestore/<database>` of the restored volume into the
   target's volume.

4. Switch the target's stable Service to the new cluster:

   ```sh
   kubectl -n $ns patch service odoo-db \
     -p '{"spec":{"selector":{"cnpg.io/cluster":"<new cluster>"}}}'
   ```

5. Update the target with `neutralize=true`, set on the command line only:

   ```sh
   helm upgrade odoo <chart> -n $ns -f values.yaml \
     --set image.digest=sha256:<digest> --set neutralize=true --wait --timeout 60m
   ```

   The update hooks take a restore point of the copy, run `odoo neutralize` (no outgoing
   mail, no scheduled actions, no calls to external services), then adapt the copy and
   update the modules from the production version. Odoo only starts on the neutralized
   database. The next update, without the flag, does not neutralize again.

The adapted copy:

- `admin` (`base.user_admin`) gets the password `admin-user-password` of the target's
  application Secret, which the update requires. Its login, and the other users with
  their passwords, stay those of production.
- With Mailpit, the server `neutralization - disable emails` that `odoo neutralize`
  creates is deleted: the production servers are archived, so mail goes to Mailpit.
  Without Mailpit, that server keeps blocking outgoing mail.
- A module installed after the neutralization brings its scheduled actions active.

### Copy the filestore volume

With Longhorn and a backup target, a `VolumeSnapshotClass` of type `bak` stores the
snapshot as a backup in remote storage, which a static `VolumeSnapshotContent` exposes
to another namespace.

1. Back the production volume up. The filestore can be copied hot: Odoo only adds files,
   named after their content.

   ```yaml
   apiVersion: snapshot.storage.k8s.io/v1
   kind: VolumeSnapshotClass
   metadata:
     name: longhorn-bak
   driver: driver.longhorn.io
   deletionPolicy: Delete
   parameters:
     type: bak
   ---
   apiVersion: snapshot.storage.k8s.io/v1
   kind: VolumeSnapshot
   metadata:
     name: odoo-data-copy
     namespace: odoo-prod
   spec:
     volumeSnapshotClassName: longhorn-bak
     source:
       persistentVolumeClaimName: odoo-odoo-data
   ```

   ```sh
   kubectl -n $prod wait volumesnapshot/odoo-data-copy \
     --for=jsonpath='{.status.readyToUse}'=true --timeout=30m
   content=$(kubectl -n $prod get volumesnapshot odoo-data-copy \
     -o jsonpath='{.status.boundVolumeSnapshotContentName}')
   kubectl get volumesnapshotcontent $content -o jsonpath='{.status.snapshotHandle}'
   kubectl -n $prod get volumesnapshot odoo-data-copy -o jsonpath='{.status.restoreSize}'
   ```

2. Restore it into a volume of the target namespace, from the handle
   (`bak://<volume>/<backup>`) and at least the size printed above. `Retain`: only the
   production `VolumeSnapshot` owns the backup.

   ```yaml
   apiVersion: snapshot.storage.k8s.io/v1
   kind: VolumeSnapshotContent
   metadata:
     name: odoo-data-from-prod
   spec:
     driver: driver.longhorn.io
     deletionPolicy: Retain
     volumeSnapshotClassName: longhorn-bak
     source:
       snapshotHandle: bak://<volume>/<backup>
     volumeSnapshotRef:
       namespace: odoo-staging
       name: odoo-data-from-prod
   ---
   apiVersion: snapshot.storage.k8s.io/v1
   kind: VolumeSnapshot
   metadata:
     name: odoo-data-from-prod
     namespace: odoo-staging
   spec:
     volumeSnapshotClassName: longhorn-bak
     source:
       volumeSnapshotContentName: odoo-data-from-prod
   ---
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: odoo-data-from-prod
     namespace: odoo-staging
   spec:
     storageClassName: longhorn
     accessModes: [ReadWriteOnce]
     resources: {requests: {storage: <size>}}
     dataSource:
       apiGroup: snapshot.storage.k8s.io
       kind: VolumeSnapshot
       name: odoo-data-from-prod
   ```

3. Once Odoo is stopped, copy the files with a Job that mounts both volumes, as the user
   of the image (`podSecurityContext`), here for the database `odoo`. The old filestore
   is kept aside to go back.

   ```yaml
   apiVersion: batch/v1
   kind: Job
   metadata:
     name: odoo-data-copy
     namespace: odoo-staging
   spec:
     backoffLimit: 0
     template:
       spec:
         restartPolicy: Never
         securityContext:
           {runAsUser: 100, runAsGroup: 101, fsGroup: 101, runAsNonRoot: true}
         containers:
           - name: copy
             image: busybox:1.37
             command: [sh, -euc]
             args:
               - |
                 if [ -d /dst/filestore/odoo ] && [ ! -d /dst/filestore/odoo.before-copy ]; then
                   mv /dst/filestore/odoo /dst/filestore/odoo.before-copy
                 fi
                 mkdir -p /dst/filestore
                 cp -a /src/filestore/odoo /dst/filestore/
             volumeMounts:
               - {name: src, mountPath: /src, readOnly: true}
               - {name: dst, mountPath: /dst}
         volumes:
           - name: src
             persistentVolumeClaim: {claimName: odoo-data-from-prod, readOnly: true}
           - name: dst
             persistentVolumeClaim: {claimName: odoo-odoo-data}
   ```

Once the copy is checked, delete the Job, the restored volume, its `VolumeSnapshot` and
`VolumeSnapshotContent`, then the production `VolumeSnapshot`, which deletes the backup.
