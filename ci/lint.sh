#!/usr/bin/env bash
# Static checks of the chart, without a cluster: helm lint and kubeconform with the
# values of tests/values (installation and update), the generated odoo.conf compared with
# an expected file, the hooks of each case, the account of the hooks, the filestore modes,
# the user of the pods, the neutralized update, and the guards (refused values, no
# destructive command in any render).
# Requires helm 4 and kubeconform (KUBECONFORM to override the binary).
# Usage: ci/lint.sh
set -euo pipefail
cd "$(dirname "$0")/.."

chart=charts/odoo
kubeconform="${KUBECONFORM:-kubeconform}"
digest="sha256:$(printf '0123456789abcdef%.0s' 1 2 3 4)"
short="${digest#sha256:}"
short="${short:0:12}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

pass() { echo "ok   $*"; }
fail() {
    echo "FAIL $*" >&2
    failures=$((failures + 1))
}
check() { # check <description> <command...>
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}

render() { # render <env> [helm args...] > manifest
    local env="$1"
    shift
    local release=odoo
    [ "$env" = review ] && release=pr-1
    helm template "$release" "$chart" -f "tests/values/$env.yaml" \
        --set image.digest="$digest" "$@"
}

doc() { # doc <file> <kind> <name>: one document of a render
    awk -v k="kind: $2" -v n="  name: $3" '
        /^---/ {if (hit) exit; buf = ""; kind = 0; name = 0; next}
        {buf = buf $0 "\n"}
        $0 == k {kind = 1}
        $0 == n {name = 1}
        kind && name {hit = 1}
        END {if (hit) printf "%s", buf}' "$1"
}
hook_of() { doc "$1" Job "$2" | sed -n 's/^    helm.sh\/hook: //p'; } # hook_of <file> <job>
has() { grep -q -- "$2" <<<"$1"; } # has <text> <pattern>
lacks() { ! grep -q -- "$2" <<<"$1"; }
equals() { [ "$1" = "$2" ]; }
fails() { ! "$@"; }

# 1. helm lint and kubeconform: review, first installation and update of the persistent
# environments
for env in review staging preprod production; do
    if helm lint --quiet "$chart" -f "tests/values/$env.yaml" \
        --set image.digest="$digest" >"$work/lint" 2>&1; then
        pass "helm lint $env"
    else
        cat "$work/lint" >&2
        fail "helm lint $env"
    fi
    render "$env" >"$work/$env.yaml"
    [ "$env" = review ] || render "$env" --is-upgrade >"$work/$env-upgrade.yaml"
done
# Update after a copy of production data: with Mailpit (staging), without (production)
for env in staging production; do
    render "$env" --is-upgrade --set neutralize=true >"$work/$env-neutralize.yaml"
done
if "$kubeconform" -strict -summary -kubernetes-version 1.34.0 \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    "$work"/*.yaml >"$work/kc" 2>&1; then
    pass "kubeconform ($(tail -1 "$work/kc"))"
else
    cat "$work/kc" >&2
    fail "kubeconform"
fi

# 2. odoo.conf generated from tests/config-values.yaml; the hook ConfigMap is
# the same
helm template t "$chart" -f tests/config-values.yaml --set image.digest="$digest" \
    --show-only templates/configmap-config.yaml >"$work/config"
conf() { # conf <ConfigMap>: its odoo.conf
    doc "$work/config" ConfigMap "$1" |
        awk '/^  odoo.conf: \|/ {f = 1; next} f {sub(/^    /, ""); print}' |
        sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}
conf t-config >"$work/odoo.conf"
if diff -u tests/odoo.conf.expected "$work/odoo.conf"; then
    pass "odoo.conf matches tests/odoo.conf.expected"
else
    fail "odoo.conf differs from tests/odoo.conf.expected"
fi
check "hook ConfigMap t-odoo-conf-hook identical to t-config" \
    diff -q "$work/odoo.conf" <(conf t-odoo-conf-hook)

# 3. Values refused by the schema or by the templates
refused() { # refused <description> <env> [helm args...]
    local description="$1"
    shift
    if render "$@" >/dev/null 2>"$work/err"; then
        fail "accepted: $description"
    else
        pass "refused: $description ($(grep -m1 -oE "(at '[^']*'.*|execution error.*)" "$work/err" | cut -c1-90))"
    fi
}
refused "environment name that is not a DNS label" staging --set environment=Staging_1
refused "ephemeral instance without review domain" review --set route.reviewDomain=
refused "neutralize on an ephemeral instance" review --set neutralize=true
refused "external database without Secret" production --set database.external.secret=
refused "external database without host" production --set database.external.host=
refused "production without application Secret" production --set secrets.existingSecret=
refused "password in odoo.conf" staging --set odoo.config.options.db_password=x
refused "secret in a module section" staging --set odoo.config.queue_job.http_auth_password=x
refused "option imposed by the chart" staging --set odoo.config.options.data_dir=/x
refused "SMTP overridden while Mailpit is enabled" review --set odoo.config.options.smtp_server=x
refused "option also set by secrets.env" staging --set odoo.config.queue_job.http_auth_user=u \
    --set-json 'secrets.env=[{"name":"ODOO_QUEUE_JOB_HTTP_AUTH_USER","secret":"s","key":"k"}]'
refused "digest that is not sha256:<64 hex>" staging --set image.digest=latest
refused "image without tag nor digest" staging --set image.digest=
refused "invalid image tag" staging --set image.digest= --set image.tag=-1.0
refused "unknown image pull policy" staging --set image.pullPolicy=Sometimes
refused "several instances on a ReadWriteOnce filestore" production --set odoo.replicas=2
refused "filestore PVC without VolumeSnapshotClass on a persistent instance" staging \
    --set restorePoints.volumeSnapshotClass=
refused "no restore point kept" production --set restorePoints.keep=0
refused "Odoo run as root" production --set podSecurityContext.runAsUser=0
refused "unknown field in podSecurityContext" production --set podSecurityContext.runAsNonRoot=false
refused "pod label value that is not a label value" staging --set podLabels.team=a/b
refused "pod label key that is not a qualified name" staging --set-json 'podLabels={"-team":"erp"}'
refused "pod annotation that is not a string" staging --set podAnnotations.ticket=1

# 4. No destructive command in any render; reviews only reset through their volumes
if grep -nEw 'dropdb|rm' "$work"/*.yaml || grep -nE 'DROP DATABASE|--force' "$work"/*.yaml; then
    fail "destructive command in a render"
else
    pass "no dropdb, DROP DATABASE, rm or --force in any render"
fi
# shellcheck disable=SC2016 # $ODOO_INIT_ADMIN_PASSWORD is expanded by the shell of the Job
db_init_without_demo() { # db_init_without_demo <render>
    local migrate
    migrate="$(doc "$work/$1.yaml" Job odoo-migrate)"
    has "$migrate" 'odoo db init --password "$ODOO_INIT_ADMIN_PASSWORD"' &&
        lacks "$migrate" with-demo && has "$migrate" "key: admin-user-password"
}
no_digest_volume() { ! grep -qE "(claimName: |name: ).*-(pgdata|odoo-data)-$short" "$work/$1.yaml"; }
for env in staging preprod production; do
    for render in "$env" "$env-upgrade"; do
        check "$render: db-init without demo, admin password of the application Secret" \
            db_init_without_demo "$render"
        check "$render: no volume named after the digest" no_digest_volume "$render"
    done
done
review_resets() {
    has "$(doc "$work/review.yaml" Job pr-1-migrate)" "init --with-demo" &&
        grep -q "pgdata-$short" "$work/review.yaml" && grep -q "odoo-data-$short" "$work/review.yaml"
}
check "review: db-init with the demo data and volumes named after the digest" review_resets

# 5. Hooks of each case
weight_of() { doc "$1" Job "$2" | sed -n 's/^    helm.sh\/hook-weight: //p'; } # weight_of <file> <job>
first_install_hooks() { # first_install_hooks <env>
    equals "$(hook_of "$work/$1.yaml" odoo-migrate)" post-install &&
        ! grep -q "name: odoo-stop-snapshot$" "$work/$1.yaml"
}
update_hooks() { # update_hooks <env>
    local file="$work/$1-upgrade.yaml"
    equals "$(hook_of "$file" odoo-stop-snapshot)/$(weight_of "$file" odoo-stop-snapshot)" 'pre-upgrade/"-5"' &&
        equals "$(hook_of "$file" odoo-migrate)/$(weight_of "$file" odoo-migrate)" 'pre-upgrade/"0"' &&
        equals "$(hook_of "$file" odoo-validate)" post-upgrade
}
check "review: migrate in post-install,post-upgrade" \
    equals "$(hook_of "$work/review.yaml" pr-1-migrate)" post-install,post-upgrade
check "review: no stop-snapshot, validate nor hooks account" \
    fails grep -qE "name: pr-1-(stop-snapshot|validate|hooks)$" "$work/review.yaml"
for env in staging preprod production; do
    check "$env, first installation: migrate in post-install, no stop-snapshot" \
        first_install_hooks "$env"
    check "$env, update: stop-snapshot (-5) then migrate (0) in pre-upgrade, validate in post-upgrade" \
        update_hooks "$env"
done
check "first installation: migrate on the node of the Odoo pod (RWO volume)" \
    has "$(doc "$work/staging.yaml" Job odoo-migrate)" podAffinity
check "update: migrate without affinity (Odoo stopped)" \
    lacks "$(doc "$work/staging-upgrade.yaml" Job odoo-migrate)" podAffinity
check "Odoo waits for its database (init container wait-db)" \
    has "$(doc "$work/staging.yaml" Deployment odoo)" "module_auto_update.installed_checksums"

# 6. Account of the hooks: only its resources and verbs
cat >"$work/role.expected" <<'ROLE'
  - {apiGroups: [apps], resources: [deployments], verbs: [get, list]}
  - {apiGroups: [apps], resources: [deployments/scale], verbs: [get, patch]}
  - {apiGroups: [""], resources: [pods], verbs: [get, list, watch]}
  - {apiGroups: [""], resources: [services], verbs: [get]}
  - {apiGroups: [postgresql.cnpg.io], resources: [clusters], verbs: [get, list, watch]}
  - {apiGroups: [postgresql.cnpg.io], resources: [backups], verbs: [create, get, list, watch, patch, delete]}
  - {apiGroups: [snapshot.storage.k8s.io], resources: [volumesnapshots], verbs: [create, get, list, watch]}
ROLE
check "Role of the hooks: only the verbs they need" \
    diff -u "$work/role.expected" <(doc "$work/production-upgrade.yaml" Role odoo-hooks | grep '^  - {')
snapshot="$(doc "$work/production-upgrade.yaml" Job odoo-stop-snapshot)"
owned_by_backup() {
    # shellcheck disable=SC2016 # $uid is expanded by the shell of the Job
    has "$snapshot" 'uid: $uid' && lacks "$snapshot" blockOwnerDeletion
}
check "filestore snapshot owned by its Backup (UID), without blockOwnerDeletion" owned_by_backup
check "hook Jobs: no automatic token" has "$snapshot" "automountServiceAccountToken: false"
check "hook Jobs: token mounted in the two kubectl containers only" \
    equals "$(grep -c "name: kube-api-access, mountPath" <<<"$snapshot")" 2

# 7. Filestore modes
render production --is-upgrade --set odoo.persistence.enabled=false --set odoo.replicas=3 \
    --set restorePoints.volumeSnapshotClass= >"$work/nopvc.yaml"
render production --set odoo.persistence.accessMode=ReadWriteMany --set odoo.replicas=3 >"$work/rwx.yaml"
render production --set odoo.persistence.existingClaim=restored-fs >"$work/claim.yaml"
no_pvc() {
    ! grep -q "kind: PersistentVolumeClaim" "$work/nopvc.yaml" &&
        lacks "$(doc "$work/nopvc.yaml" Job odoo-stop-snapshot)" "kind: VolumeSnapshot" &&
        has "$(doc "$work/nopvc.yaml" Deployment odoo)" "replicas: 3"
}
shared_pvc() {
    grep -q "accessModes: \[ReadWriteMany\]" "$work/rwx.yaml" &&
        lacks "$(doc "$work/rwx.yaml" Job odoo-migrate)" podAffinity
}
existing_claim() {
    ! grep -q "kind: PersistentVolumeClaim" "$work/claim.yaml" &&
        grep -q "claimName: restored-fs" "$work/claim.yaml"
}
check "no PVC: no volume, /var/lib/odoo on an emptyDir, restore point = the Backup only" no_pvc
check "shared filestore: ReadWriteMany volume, 3 instances, no affinity" shared_pvc
check "existing claim: no PVC rendered, Odoo on restored-fs" existing_claim

# 8. User of the Odoo pods: that of the image, or left to the platform
pod_user() { # pod_user <render> <kind> <name>: the pod security context, on one line
    doc "$1" "$2" "$3" | awk '/^      securityContext:/ {f = 1; next}
        f && /^      [a-z]/ {exit} f {gsub(/^ +/, ""); printf "%s ", $0}'
}
default_user="runAsNonRoot: true fsGroup: 101 runAsGroup: 101 runAsUser: 100 fsGroupChangePolicy: OnRootMismatch seccompProfile: type: RuntimeDefault "
check "default: Odoo as the user odoo of the official image (100:101)" \
    equals "$(pod_user "$work/production.yaml" Deployment odoo)" "$default_user"
check "default: hook Jobs of the Odoo image as the same user" \
    equals "$(pod_user "$work/production-upgrade.yaml" Job odoo-migrate)" "$default_user"
render production --set podSecurityContext.runAsUser=1000 --set podSecurityContext.runAsGroup=1000 \
    --set podSecurityContext.fsGroup=1000 >"$work/uid.yaml"
check "podSecurityContext: user of another image (1000:1000)" \
    equals "$(pod_user "$work/uid.yaml" Deployment odoo)" \
    "runAsNonRoot: true fsGroup: 1000 runAsGroup: 1000 runAsUser: 1000 fsGroupChangePolicy: OnRootMismatch seccompProfile: type: RuntimeDefault "
render production --set podSecurityContext=null >"$work/nouid.yaml"
check "podSecurityContext null: user left to the platform, still non-root" \
    equals "$(pod_user "$work/nouid.yaml" Deployment odoo)" \
    "runAsNonRoot: true seccompProfile: type: RuntimeDefault "

# 9. Image of the Odoo containers: digest, tag, or both (the digest decides)
repository=ghcr.io/owner/repo/builds
odoo_images() { sed -n "s|^ *image: \($repository.*\)|\1|p" "$1" | sort -u; } # odoo_images <render>
check "digest: every Odoo container on repository@digest" \
    equals "$(odoo_images "$work/staging-upgrade.yaml")" "$repository@$digest"
render staging --is-upgrade --set image.tag=1.0.0 >"$work/tag-digest.yaml"
check "tag and digest: repository:tag@digest" \
    equals "$(odoo_images "$work/tag-digest.yaml")" "$repository:1.0.0@$digest"
render review --set image.digest= --set image.tag=1.0.0 >"$work/tag.yaml"
tag_key="$(printf %s "$repository:1.0.0" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-12)"
tag_only() {
    equals "$(odoo_images "$work/tag.yaml")" "$repository:1.0.0" &&
        grep -q "pgdata-$tag_key" "$work/tag.yaml" && grep -q "odoo-data-$tag_key" "$work/tag.yaml"
}
check "tag only: repository:tag, review volumes named after a hash of the image" tag_only
# 10. Probes of Odoo: liveness on TCP (a module install from the interface blocks a
# threaded Odoo), readiness and startup on /web/health
odoo_probe() { # odoo_probe <render> <probe>: the probe of the container odoo, on one line
    doc "$1" Deployment odoo | awk -v p="          $2:" '$0 == p {f = 1; next}
        f && !/^            / {exit} f {gsub(/^ +/, ""); printf "%s ", $0}'
}
check "liveness: TCP on the HTTP port" \
    equals "$(odoo_probe "$work/staging.yaml" livenessProbe)" "tcpSocket: {port: http} periodSeconds: 30 timeoutSeconds: 5 failureThreshold: 3 "
check "readiness: HTTP /web/health" has "$(odoo_probe "$work/staging.yaml" readinessProbe)" "httpGet: {path: /web/health"
check "pull policy: Kubernetes default when empty" fails grep -q imagePullPolicy "$work/staging-upgrade.yaml"
render staging --is-upgrade --set image.pullPolicy=Always >"$work/pull.yaml"
check "pull policy Always on every Odoo container" equals \
    "$(grep -c "imagePullPolicy: Always" "$work/pull.yaml")" "$(grep -c "image: $repository" "$work/pull.yaml")"

# 11. Metadata of the Odoo pods: version label from the tag, podLabels and podAnnotations
# added without overriding the chart's keys
pod_metadata() { # pod_metadata <render> <labels|annotations>: of the Odoo pod, one per line
    doc "$1" Deployment odoo | awk -v m="      $2:" '$0 == m {f = 1; next}
        f && !/^        / {exit} f {gsub(/^ +/, ""); print}'
}
check "no tag: no version label" \
    fails grep -q "app.kubernetes.io/version" "$work/staging-upgrade.yaml"
check "tag: version label on the Deployment and its pods" \
    equals "$(grep -c 'app.kubernetes.io/version: "1.0.0"' "$work/tag-digest.yaml")" 2
render staging --is-upgrade --set image.tag=_1.0.0- >"$work/odd-tag.yaml"
check "tag with non-alphanumeric ends: trimmed version label" \
    has "$(pod_metadata "$work/odd-tag.yaml" labels)" 'app.kubernetes.io/version: "1.0.0"$'
render staging --is-upgrade --set podLabels.team=erp --set podLabels.app\\.kubernetes\\.io/name=x \
    --set podAnnotations.example\\.com/ticket=T-1 --set podAnnotations.checksum/config=x \
    >"$work/pod-metadata.yaml"
labels="$(pod_metadata "$work/pod-metadata.yaml" labels)"
annotations="$(pod_metadata "$work/pod-metadata.yaml" annotations)"
check "podLabels: added to the Odoo pods" has "$labels" "^team: erp$"
check "podLabels: the chart's labels win (selector intact)" \
    equals "$(grep -c '^app.kubernetes.io/name:' <<<"$labels")/$(grep '^app.kubernetes.io/name:' <<<"$labels")" \
    "1/app.kubernetes.io/name: odoo"
check "podAnnotations: added to the Odoo pods" has "$annotations" "^example.com/ticket: T-1$"
check "podAnnotations: the chart's annotations win" \
    equals "$(grep '^checksum/config:' <<<"$annotations")" \
    "$(grep '^checksum/config:' <<<"$(pod_metadata "$work/staging-upgrade.yaml" annotations)")"

# 12. Neutralized update: admin password of this instance, mail to Mailpit when enabled
migrate_steps() { # migrate_steps <render>: the containers of the Job migrate, in order
    doc "$1" Job odoo-migrate | awk '/^      volumes:/ {exit} sub(/^        - name: /, "") {printf "%s ", $0}'
}
migrate_container() { # migrate_container <render> <container>: its lines
    doc "$1" Job odoo-migrate | awk -v n="        - name: $2" '$0 == n {f = 1; print; next}
        f && /^        - name:|^      [a-z]/ {exit} f {print}'
}
admin_password() { # admin_password <render>: adapt sets it from admin-user-password, then commits
    local adapt
    adapt="$(migrate_container "$1" adapt)"
    has "$adapt" 'base.user_admin").password = os.environ' &&
        has "$adapt" "key: admin-user-password" && has "$adapt" "env.cr.commit()"
}
check "neutralize: db-init, neutralize, adapt, install, update" \
    equals "$(migrate_steps "$work/staging-neutralize.yaml")" "db-init neutralize adapt install update "
check "no neutralize: neither neutralize nor adapt" \
    equals "$(migrate_steps "$work/staging-upgrade.yaml")" "db-init install update "
check "neutralize: db-init requires admin-user-password before any change" \
    has "$(migrate_container "$work/staging-neutralize.yaml" db-init)" "needed to neutralize"
check "no neutralize: db-init does not require admin-user-password on update" \
    lacks "$(migrate_container "$work/staging-upgrade.yaml" db-init)" "needed to neutralize"
for env in staging production; do
    check "$env neutralize: admin password from admin-user-password" admin_password "$work/$env-neutralize.yaml"
done
check "neutralize with Mailpit: adapt drops the dummy mail server of odoo neutralize" \
    has "$(migrate_container "$work/staging-neutralize.yaml" adapt)" '("smtp_host", "=", "invalid")'
check "neutralize without Mailpit: the dummy mail server stays" \
    lacks "$(migrate_container "$work/production-neutralize.yaml" adapt)" "invalid"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '### Chart checks\n\n- failures: %s\n' "$failures" >>"$GITHUB_STEP_SUMMARY"
fi
if [ "$failures" -gt 0 ]; then
    echo "lint: $failures check(s) FAILED" >&2
    exit 1
fi
echo "lint: all checks passed."
