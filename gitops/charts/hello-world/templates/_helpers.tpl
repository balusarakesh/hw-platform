{{- define "hello-world.labels" -}}
app.kubernetes.io/name: hello-world
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "hello-world.selectorLabels" -}}
app.kubernetes.io/name: hello-world
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* repo:tag@digest: pulls are pinned to the digest even if someone re-pushes the tag. */}}
{{- define "hello-world.image" -}}
{{- required "image.repository is required" .Values.image.repository }}:{{ required "image.tag is required" .Values.image.tag }}@{{ required "image.digest is required" .Values.image.digest }}
{{- end }}

{{/* Shared hardened security contexts (PSA "restricted" compliant). */}}
{{- define "hello-world.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 65532
runAsGroup: 65532
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- define "hello-world.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
privileged: false
capabilities:
  drop: [ALL]
{{- end }}

{{- define "hello-world.dbEnv" -}}
- { name: AWS_REGION, value: {{ .Values.region | quote }} }
- { name: DB_HOST, value: {{ .Values.db.host | quote }} }
- { name: DB_PORT, value: {{ .Values.db.port | quote }} }
- { name: DB_NAME, value: {{ .Values.db.name | quote }} }
- { name: DB_USER, value: {{ .Values.db.user | quote }} }
{{- end }}
