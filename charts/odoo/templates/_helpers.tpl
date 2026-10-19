{{/* Names */}}
{{- define "odoo.shortDigest" -}}
{{ trimPrefix "sha256:" .Values.image.digest | trunc 12 }}
{{- end }}

{{- define "odoo.image" -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- end }}

{{- define "odoo.ephemeral" -}}
{{- if .Values.ephemeral }}true{{ end }}
{{- end }}

{{/* Filestore volume: ephemeral volumes carry the digest (reset on a new image) */}}
{{- define "odoo.dataClaim" -}}
{{- if .Values.odoo.persistence.existingClaim -}}
{{ .Values.odoo.persistence.existingClaim }}
{{- else if include "odoo.ephemeral" . -}}
{{ .Release.Name }}-odoo-data-{{ include "odoo.shortDigest" . }}
{{- else -}}
{{ .Release.Name }}-odoo-data
{{- end }}
{{- end }}

{{/* Restore points (persistent instances) */}}
{{- define "odoo.restorePoints" -}}
{{- if not (include "odoo.ephemeral" .) }}true{{ end }}
{{- end }}

{{/* ConfigMap of the hook Jobs: same content, created before them */}}
{{- define "odoo.hookConfig" -}}
{{ .Release.Name }}-odoo-conf-hook
{{- end }}

{{/* Stable Service of the database (first label of database.external.host) */}}
{{- define "odoo.dbService" -}}
{{ .Values.database.external.host | splitList "." | first }}
{{- end }}

{{- define "odoo.pgdataClaim" -}}
{{ .Release.Name }}-pgdata-{{ include "odoo.shortDigest" . }}
{{- end }}

{{- define "odoo.generatedSecret" -}}
{{ .Release.Name }}-secrets
{{- end }}

{{- define "odoo.appSecret" -}}
{{ .Values.secrets.existingSecret | default (include "odoo.generatedSecret" .) }}
{{- end }}

{{- define "odoo.workers" -}}
{{ index .Values.odoo.config "options" | default dict | dig "workers" 0 | int }}
{{- end }}

{{- define "odoo.host" -}}
{{- if include "odoo.ephemeral" . -}}
{{ .Values.project }}-{{ .Release.Name }}.{{ .Values.route.reviewDomain }}
{{- else -}}
{{ .Values.route.host }}
{{- end }}
{{- end }}

{{- define "odoo.mailpitHost" -}}
{{- if include "odoo.ephemeral" . -}}
{{ .Values.project }}-{{ .Release.Name }}-mail.{{ .Values.route.reviewDomain }}
{{- else -}}
{{ .Values.route.mailpitHost }}
{{- end }}
{{- end }}

{{/* Labels */}}
{{- define "odoo.selectorLabels" -}}
app.kubernetes.io/name: odoo
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "odoo.labels" -}}
{{ include "odoo.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- if .Values.environment }}
{{ .Values.labelPrefix }}/environment: {{ .Values.environment }}
{{- end }}
{{- end }}

{{/* odoo.conf values: lists joined by commas, booleans as True/False, whole numbers as integers */}}
{{- define "odoo.iniScalar" -}}
{{- if kindIs "bool" . -}}
{{ ternary "True" "False" . }}
{{- else if kindIs "float64" . -}}
{{- if eq (float64 (int64 .)) . }}{{ int64 . }}{{ else }}{{ . }}{{ end }}
{{- else -}}
{{ . }}
{{- end }}
{{- end }}

{{- define "odoo.iniValue" -}}
{{- if kindIs "slice" . -}}
{{- $items := list -}}
{{- range . }}{{ $items = append $items (include "odoo.iniScalar" .) }}{{ end -}}
{{ join "," $items }}
{{- else -}}
{{ include "odoo.iniScalar" . }}
{{- end }}
{{- end }}

{{/* odoo.conf: [options] first (imposed options, then the values), then the
other sections in alphabetical order */}}
{{- define "odoo.conf" -}}
[options]
data_dir = /var/lib/odoo
http_interface = 0.0.0.0
{{- if .Values.mailpit.enabled }}
smtp_server = localhost
smtp_port = 1025
{{- end }}
{{- $options := index .Values.odoo.config "options" | default dict }}
{{- range $name := keys $options | sortAlpha }}
{{- $value := index $options $name }}
{{- if not (kindIs "invalid" $value) }}
{{ $name }} = {{ include "odoo.iniValue" $value }}
{{- end }}
{{- end }}
{{- range $section := keys .Values.odoo.config | sortAlpha }}
{{- if ne $section "options" }}
{{- $opts := index $.Values.odoo.config $section | default dict }}

[{{ $section }}]
{{- range $name := keys $opts | sortAlpha }}
{{- $value := index $opts $name }}
{{- if not (kindIs "invalid" $value) }}
{{ $name }} = {{ include "odoo.iniValue" $value }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/* Guards, evaluated by the ConfigMap, which every render contains */}}
{{- define "odoo.validate" -}}
{{- $v := .Values -}}
{{- if and $v.environment (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $v.environment)) -}}
{{- fail "environment must be a DNS label (lowercase letters, digits, hyphens)" -}}
{{- end -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $v.image.digest) -}}
{{- fail "image.digest must be sha256:<64 hex>" -}}
{{- end -}}
{{- if and $v.ephemeral $v.neutralize -}}
{{- fail "neutralize is for a copy of another instance's data, not for ephemeral=true" -}}
{{- end -}}
{{- if and (not $v.ephemeral) (not $v.secrets.existingSecret) -}}
{{- fail "secrets.existingSecret is required unless ephemeral=true" -}}
{{- end -}}
{{- $p := $v.odoo.persistence -}}
{{- if and (gt (int $v.odoo.replicas) 1) $p.enabled (eq $p.accessMode "ReadWriteOnce") -}}
{{- fail "odoo.replicas > 1 needs a shared filestore: odoo.persistence.accessMode=ReadWriteMany, or odoo.persistence.enabled=false with the filestore on S3" -}}
{{- end -}}
{{- if and (include "odoo.restorePoints" .) $p.enabled (not $v.restorePoints.volumeSnapshotClass) -}}
{{- fail "restorePoints.volumeSnapshotClass is required for the filestore snapshot unless ephemeral=true (or odoo.persistence.enabled=false)" -}}
{{- end -}}
{{- if lt (int $v.restorePoints.keep) 1 -}}
{{- fail "restorePoints.keep must be at least 1" -}}
{{- end -}}
{{- if and (not $v.ephemeral) (not $v.database.external.secret) -}}
{{- fail "database.external.secret is required unless ephemeral=true" -}}
{{- end -}}
{{- if and (not $v.ephemeral) (not $v.database.external.host) -}}
{{- fail "database.external.host (stable Service of the CNPG cluster) is required unless ephemeral=true" -}}
{{- end -}}
{{- if $v.route.parentRefs -}}
{{- if and $v.ephemeral (not $v.route.reviewDomain) -}}
{{- fail "route.reviewDomain is required with ephemeral=true and route.parentRefs" -}}
{{- end -}}
{{- if and (not $v.ephemeral) (not $v.route.host) -}}
{{- fail "route.host is required with route.parentRefs" -}}
{{- end -}}
{{- end -}}
{{- $envNames := list -}}
{{- range $v.secrets.env }}{{ $envNames = append $envNames .name }}{{ end -}}
{{- range $section, $opts := $v.odoo.config -}}
{{- if not (regexMatch "^[a-z0-9_.]+$" $section) -}}
{{- fail (printf "odoo.config: invalid section name %q" $section) -}}
{{- end -}}
{{- range $name, $_ := $opts -}}
{{- if not (regexMatch "^[a-z0-9_.]+$" $name) -}}
{{- fail (printf "odoo.config.%s: invalid option name %q" $section $name) -}}
{{- end -}}
{{- if regexMatch "passw|secret|token" $name -}}
{{- fail (printf "odoo.config.%s.%s: secrets go in secrets.env, not in odoo.conf" $section $name) -}}
{{- end -}}
{{- if and (eq $section "options") (has $name (list "data_dir" "http_interface")) -}}
{{- fail (printf "odoo.config.options.%s is set by the chart" $name) -}}
{{- end -}}
{{- if and (eq $section "options") $v.mailpit.enabled (has $name (list "smtp_server" "smtp_port")) -}}
{{- fail (printf "odoo.config.options.%s is set by the chart when Mailpit is enabled" $name) -}}
{{- end -}}
{{- $envName := ternary (printf "ODOO_%s" ($name | upper)) (printf "ODOO_%s_%s" ($section | upper) ($name | upper)) (eq $section "options") -}}
{{- if has $envName $envNames -}}
{{- fail (printf "odoo.config.%s.%s is also set by secrets.env (%s)" $section $name $envName) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/* Pod and container hardening (PSA restricted) */}}
{{- define "odoo.podSecurityContext" -}}
{{- $ids := .Values.podSecurityContext | default dict -}}
runAsNonRoot: true
{{- range $field, $id := $ids }}
{{- if not (kindIs "invalid" $id) }}
{{ $field }}: {{ $id | int64 }}
{{- end }}
{{- end }}
{{- if and (hasKey $ids "fsGroup") (not (kindIs "invalid" (index $ids "fsGroup"))) }}
fsGroupChangePolicy: OnRootMismatch
{{- end }}
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- define "odoo.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end }}

{{/* Environment of Odoo and of the Jobs: secrets read natively by Odoo 20 */}}
{{- define "odoo.env" -}}
- name: ODOO_RC
  value: /etc/odoo/odoo.conf
{{- if .Values.ephemeral }}
- name: PGHOST
  value: {{ .Release.Name }}-postgres
- name: PGPORT
  value: "5432"
- name: PGUSER
  value: odoo
- name: PGPASSWORD
  valueFrom:
    secretKeyRef: {name: {{ include "odoo.generatedSecret" . }}, key: pg-password}
{{- else }}
- name: PGHOST
  value: {{ .Values.database.external.host | quote }}
- name: PGPORT
  value: {{ .Values.database.external.port | quote }}
{{- range $env, $key := dict "PGUSER" "username" "PGPASSWORD" "password" }}
- name: {{ $env }}
  valueFrom:
    secretKeyRef: {name: {{ $.Values.database.external.secret }}, key: {{ $key }}}
{{- end }}
{{- end }}
- name: PGDATABASE
  value: {{ .Values.database.name | quote }}
- name: ODOO_ADMIN_PASSWD
  valueFrom:
    secretKeyRef: {name: {{ include "odoo.appSecret" . }}, key: admin-passwd}
{{- if .Values.secrets.existingSecret }}
- name: ODOO_SMTP_PASSWORD
  valueFrom:
    secretKeyRef: {name: {{ .Values.secrets.existingSecret }}, key: smtp-password, optional: true}
{{- end }}
{{- range .Values.secrets.env }}
- name: {{ .name }}
  valueFrom:
    secretKeyRef: {name: {{ .secret }}, key: {{ .key }}}
{{- end }}
{{- end }}

{{- define "odoo.volumeMounts" -}}
- {name: config, mountPath: /etc/odoo, readOnly: true}
- {name: data, mountPath: /var/lib/odoo}
- {name: tmp, mountPath: /tmp}
{{- end }}

{{/* Volumes of Odoo (and of the migrate Job, with the hook ConfigMap): (list . "<ConfigMap>") */}}
{{- define "odoo.volumesWith" -}}
{{- $root := index . 0 -}}
- name: config
  configMap: {name: {{ index . 1 }}}
- name: data
  {{- if $root.Values.odoo.persistence.enabled }}
  persistentVolumeClaim: {claimName: {{ include "odoo.dataClaim" $root }}}
  {{- else }}
  emptyDir: {}
  {{- end }}
- name: tmp
  emptyDir: {}
{{- end }}

{{- define "odoo.volumes" -}}
{{ include "odoo.volumesWith" (list . (printf "%s-config" .Release.Name)) }}
{{- end }}

{{/* Pod settings; (list . "<ServiceAccount>") for the hook Jobs of the hooks account */}}
{{- define "odoo.podCommon" -}}
{{- $root := . }}
{{- $account := "" }}
{{- if kindIs "slice" . }}
{{- $root = index . 0 }}
{{- $account = index . 1 }}
{{- end -}}
serviceAccountName: {{ $account | default $root.Release.Name }}
automountServiceAccountToken: false
securityContext:
  {{- include "odoo.podSecurityContext" $root | nindent 2 }}
{{- with $root.Values.image.pullSecrets }}
imagePullSecrets:
  {{- range . }}
  - name: {{ . }}
  {{- end }}
{{- end }}
{{- end }}

{{/* Hooks of the chart: annotations, given the events and the weight */}}
{{- define "odoo.hook" -}}
helm.sh/hook: {{ index . 0 }}
helm.sh/hook-weight: {{ index . 1 | quote }}
helm.sh/hook-delete-policy: before-hook-creation
{{- end }}

{{/* Containers of the stop-snapshot and validate Jobs: sh and kubectl */}}
{{- define "odoo.kubectlContainer" -}}
image: {{ .Values.restorePoints.image }}
command: [sh, -euc]
resources:
  {{- toYaml .Values.restorePoints.resources | nindent 2 }}
securityContext:
  runAsUser: 65532
  runAsGroup: 65532
  {{- include "odoo.containerSecurityContext" . | nindent 2 }}
volumeMounts:
  - {name: tmp, mountPath: /tmp}
  - {name: kube-api-access, mountPath: /var/run/secrets/kubernetes.io/serviceaccount, readOnly: true}
{{- end }}

{{- define "odoo.kubectlEnv" -}}
- {name: HOME, value: /tmp}
- {name: REL, value: {{ .Release.Name | quote }}}
- {name: P, value: {{ .Values.labelPrefix | quote }}}
{{- end }}

{{/* Token of the hooks account, mounted in the kubectl containers only */}}
{{- define "odoo.kubeApiAccess" -}}
- name: kube-api-access
  projected:
    sources:
      - serviceAccountToken: {path: token, expirationSeconds: 3600}
      - configMap: {name: kube-root-ca.crt, items: [{key: ca.crt, path: ca.crt}]}
      - downwardAPI: {items: [{path: namespace, fieldRef: {fieldPath: metadata.namespace}}]}
{{- end }}

{{/* Label selector of the restore points of the release, for kubectl */}}
{{- define "odoo.pointSelector" -}}
app.kubernetes.io/instance={{ .Release.Name }},{{ .Values.labelPrefix }}/backup-type=pre-upgrade
{{- end }}

{{/* Shell function "points <state>": "<name> <phase> <filestore snapshot>" per Backup of
the release in that state, oldest first; "complete <phase> <filestore>": the Backup is
completed and its filestore snapshot, if any, ready to use */}}
{{- define "odoo.pointFunctions" -}}
{{- $escaped := .Values.labelPrefix | replace "." "\\." -}}
points() {
  kubectl get backups.postgresql.cnpg.io --sort-by=.metadata.creationTimestamp \
    -l "{{ include "odoo.pointSelector" . }},$P/upgrade-state in ($1)" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{.metadata.annotations.{{ $escaped }}/filestore}{"\n"}{end}'
}
complete() {
  [ "$1" = completed ] || return 1
  [ -z "${2:-}" ] && return 0
  [ "$(kubectl get volumesnapshots.snapshot.storage.k8s.io "$2" -o jsonpath='{.status.readyToUse}' 2>/dev/null)" = true ]
}
{{- end }}
