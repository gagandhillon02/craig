{{- define "craig.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}

{{- define "craig.image" -}}
{{- printf "%s/%s:%s" $.Values.images.repositoryPrefix .name $.Values.images.tag -}}
{{- end -}}

{{- define "craig.imagePullSecrets" -}}
{{- if .Values.images.pullSecrets }}
imagePullSecrets:
{{- range .Values.images.pullSecrets }}
  - name: {{ . | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "craig.keycloakIssuer" -}}
{{- printf "%s://%s/realms/craig" .Values.global.externalScheme .Values.global.hosts.keycloak -}}
{{- end -}}

{{- define "craig.webExternalUrl" -}}
{{- printf "%s://%s" .Values.global.externalScheme .Values.global.hosts.app -}}
{{- end -}}

{{- define "craig.postgresHost" -}}
{{- if .Values.postgres.enabled -}}craig-postgres{{- else -}}postgres{{- end -}}
{{- end -}}

{{- define "craig.rabbitmqHost" -}}
{{- if .Values.rabbitmq.enabled -}}craig-rabbitmq{{- else -}}rabbitmq{{- end -}}
{{- end -}}

{{- define "craig.dbUserStem" -}}
{{- replace "-" "_" . -}}
{{- end -}}

{{- define "craig.appDatabaseUrl" -}}
{{- $root := .root -}}
{{- $name := .name -}}
{{- $db := .db -}}
{{- if $root.Values.postgres.useDevstackRoles -}}
{{- $stem := include "craig.dbUserStem" $name -}}
{{- printf "postgres://%s_app:%s_app@%s:5432/%s" $stem $stem (include "craig.postgresHost" $root) $db -}}
{{- else -}}
{{- printf "postgres://%s:$(POSTGRES_PASSWORD)@%s:5432/%s" $root.Values.postgres.user (include "craig.postgresHost" $root) $db -}}
{{- end -}}
{{- end -}}

{{- define "craig.ownerDatabaseUrl" -}}
{{- $root := .root -}}
{{- $name := .name -}}
{{- $db := .db -}}
{{- if $root.Values.postgres.useDevstackRoles -}}
{{- $stem := include "craig.dbUserStem" $name -}}
{{- printf "postgres://%s_owner:%s_owner@%s:5432/%s" $stem $stem (include "craig.postgresHost" $root) $db -}}
{{- else -}}
{{- printf "postgres://%s:$(POSTGRES_PASSWORD)@%s:5432/%s" $root.Values.postgres.user (include "craig.postgresHost" $root) $db -}}
{{- end -}}
{{- end -}}
