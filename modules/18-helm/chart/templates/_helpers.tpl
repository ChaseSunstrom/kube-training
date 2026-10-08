{{/*
_helpers.tpl - named templates ("partials") reused by the other templates.
Files starting with "_" are not rendered into manifests themselves.
Call them with: {{ include "webapp.fullname" . }}
*/}}

{{/* Chart name, overridable with nameOverride. */}}
{{- define "webapp.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Full name used for object names: "<release>-<chart>", or just "<release>"
if the release name already contains the chart name. Kubernetes names are
limited to 63 characters for many kinds, hence trunc.
*/}}
{{- define "webapp.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/* "webapp-0.1.0" - goes into the helm.sh/chart label. */}}
{{- define "webapp.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels: MUST stay stable for the life of a release, because a
Deployment's selector is immutable. Never put the chart version here.
*/}}
{{- define "webapp.selectorLabels" -}}
app: {{ include "webapp.fullname" . }}
app.kubernetes.io/name: {{ include "webapp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Full label set for metadata.labels (selector labels + informational ones). */}}
{{- define "webapp.labels" -}}
{{ include "webapp.selectorLabels" . }}
helm.sh/chart: {{ include "webapp.chart" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Image reference: tag defaults to the chart's appVersion. */}}
{{- define "webapp.image" -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) }}
{{- end }}

{{/* ServiceAccount name. */}}
{{- define "webapp.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "webapp.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Security settings shared by every pod/container in the chart: non-root,
read-only, no capabilities - passes the "restricted" Pod Security level.
*/}}
{{- define "webapp.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 101
runAsGroup: 101
fsGroup: 101
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- define "webapp.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end }}
