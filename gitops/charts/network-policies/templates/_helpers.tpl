{{/* Default deny for every pod in a namespace (both directions unless only ingress is given). */}}
{{- define "np.defaultDeny" -}}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: {{ .ns }}
spec:
  podSelector: {}
  policyTypes: {{ .types | default (list "Ingress" "Egress") | toJson }}
{{- end }}

{{/* What every pod needs: DNS and the EKS Pod Identity agent (credentials). */}}
{{- define "np.baseEgress" -}}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-pod-identity
  namespace: {{ .ns }}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: kube-system }
          podSelector:
            matchLabels: { k8s-app: kube-dns }
        - ipBlock: { cidr: {{ .root.Values.kubeDnsIp }}/32 }
      ports:
        - { protocol: UDP, port: 53 }
        - { protocol: TCP, port: 53 }
    - to:
        - ipBlock: { cidr: {{ .root.Values.podIdentityAgent }} }
      ports:
        - { protocol: TCP, port: 80 }
{{- end }}

{{/* HTTPS anywhere: AWS APIs (Route 53, Secrets Manager, STS, ECR, KMS), GitHub, and the EKS API. */}}
{{- define "np.httpsOut" -}}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-https-egress
  namespace: {{ .ns }}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - ipBlock: { cidr: 0.0.0.0/0 }
      ports:
        - { protocol: TCP, port: 443 }
{{- end }}
