
################################################################################
# ArgoCD
################################################################################
resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  namespace  = local.namespaces.devops
  chart      = "argo-cd"
  version    = "8.1.0"
  wait       = true

  values = [
    <<-EOT
      
    redis-ha:
      enabled: ${terraform.workspace == "prd" ? true : false}

    controller:
      replicas: 2

    server:
      autoscaling:
        enabled: true
        minReplicas: 2

    repoServer:
      autoscaling:
        enabled: true
        minReplicas: 2

    applicationSet:
      replicas: 0

    configs:
      repositories: {}

      params:
        server.insecure: true

      cm:
        accounts.admin: apiKey, login
        accounts.github: apiKey, login
        resource.compareoptions: |
          ignoreResourceStatusField: all
          ignoreDifferencesOnResourceUpdates: true

    EOT
  ]

  depends_on = [
    azurerm_kubernetes_cluster.main,
    helm_release.vault
  ]
}

resource "kubectl_manifest" "argocd_project_addons" {
  yaml_body = <<EOF
  apiVersion: argoproj.io/v1alpha1
  kind: AppProject
  metadata:
    name: addons-project
    namespace: ${local.namespaces.devops}
  spec:
    clusterResourceWhitelist:
      - group: '*'
        kind: '*'
    destinations:
      - namespace: '*'
        server: '*'
    sourceRepos:
      - '*'
  EOF
  depends_on = [ helm_release.argocd ]
}

resource "kubectl_manifest" "argocd_project_jarvix" {
  yaml_body = <<EOF
  apiVersion: argoproj.io/v1alpha1
  kind: AppProject
  metadata:
    name: jarvix-project
    namespace: ${local.namespaces.devops}
  spec:
    clusterResourceWhitelist:
      - group: '*'
        kind: '*'
    destinations:
      - namespace: '${local.namespaces.jarvix}'
        server: '*'
    sourceRepos:
      - '*'
  EOF
  depends_on = [ helm_release.argocd ]
}

################################################################################
# ArgoCD Repository - GitOps
################################################################################
resource "kubectl_manifest" "argocd_repo_gitops" {
  yaml_body = <<-EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: repo-gitops
      namespace: ${local.namespaces.devops}
      labels:
        argocd.argoproj.io/secret-type: repository
      annotations:
        managed-by: argocd.argoproj.io
    type: Opaque
    stringData:
      type: git
      url: https://github.com/lurodrisilva/gitops.git
  EOF
  depends_on = [helm_release.argocd]
}

################################################################################
# ArgoCD Application - GitOps
################################################################################
resource "kubectl_manifest" "argocd_app_gitops" {
  yaml_body = <<-EOF
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: gitops
      namespace: ${local.namespaces.devops}
    spec:
      project: addons-project
      source:
        repoURL: https://github.com/lurodrisilva/gitops.git
        targetRevision: HEAD
        path: base_chart
      destination:
        server: https://kubernetes.default.svc
        namespace: ${local.namespaces.devops}
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
  EOF
  depends_on = [helm_release.argocd, kubectl_manifest.argocd_repo_gitops]
}

# resource "kubectl_manifest" "argocd_repo_helm_charts" {
#   yaml_body = <<EOF
#   apiVersion: v1
#   kind: Secret
#   metadata:
#     name: repo-aks-foundation
#     namespace: ${local.namespaces.devops}
#     labels:
#       argocd.argoproj.io/secret-type: repository
#     annotations:
#       managed-by: argocd.argoproj.io
#   type: Opaque
#   data:
#     githubAppID: OTcyNjQ2
#     githubAppInstallationID: NTM4NzEyNjM=
#     githubAppPrivateKey: >-
#       LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQpNSUlFb2dJQkFBS0NBUUVBOEhTVG1uZTBORTRhNlNOMVlzRndsZm1MSzRBR3pwdTVKTFU5Y2VVMDh0dithcGU3Cm1PY2xLaXlPSEltYTFmM0hCOVhxcDNnVWJKaTQvUXI2UldoVS82SFpiMUFkTFhrMGh3S0FrRm44NXh5enZBV2QKVWlXMmJVYnBuZFcxMHE5bUU0bXp2ZG1taW9tSmZwK1JiczVvL0lqNWt3Sk5lM2wrVy9YNXE0aC9uYTBqdGJ3dwpsckF0RnJSNWRtazhQOUpDNWY1L2Ywc0xMTWVXYUY4SWovTXFxSzh5N2kzZzhnWWNWNHQvT0hnRmtwSnRGYU4wCkJBTUxtbzY0OGR3ai8ycW90UnMwSFM3Q0lyUTQwUkNsV0lVaUxBTXM2QUNmbXVSdVhtazRkSW9YMW9Edlp6alUKSk5Gdk9KM2kvRm5wckRqZXpEem5PTXd0N1hOQnV1ZldqZGxYWndJREFRQUJBb0lCQUUxSm16djJKK1Q4Q2VoUAo3bVlzdVF4cnBsRDRHTGdHRTY5NTFlTXJBaWJoa1ZnZnB6dlJaLyt6VElaZHNIZ0IxeHhzcEx6cGV0OGhBNnpKCi80R1p0R0JxWEdKTUJPVGQ1WVZUeDVFZWE0eTVqQWZ1WWcvS2NXV1Vlbml4L1h4WHhsNlhUei9CbXFkQzUvL2MKT0RtK2ZMNVhKS2tjLzF5bHczaTVpbU9aUHpPbG1KbG1WMjVZcXVFbFgrWVRrYnhwWjJlTnRBWllTVkNLMkw3ego4WHJhYkFTOGdZamowYThOSldCMy9vZXpXUkZWWktmK2k3WHlJckFGdnV3NTNHbC9COFQxNkRjQlE4NnVKZEY3Ci82UENCMTM5MW9mR01ZT1VKNVhMaGlFaVc0ZDAvWjNKR09OUzZ4Y2xUNlZLaHh3dGdiZ3FPSWxDNTNvcm8vMlIKZ1MyTDFua0NnWUVBLzN0RklvdUcvc1FHRmIwc1JjRGk4UkM1akJQUmM2WTFBdnR1MlUrcE9JOXNZMFFqQi9teQpHRkpJcXZCamdjcSsyN1duOVFZc0h6LzBqQzRyenlkSGRRRCs2VTlQSGlDNGZZSDg4TkhGYnNOa0M3Rk90ejdVCllrcG5TNktwYTdsVDNMZUZXZnVnTElXS2RFZmc3UE9TRnJKUVIyL1dRSUp6bXI2bXhrS3dzSE1DZ1lFQThQR0EKQUZ6L1BScGw4aUFWQk1tdmRXZXZpVng1ZkpXNXArNEt0WUdaZWI4NTZYamEvcWhhTHlUQnVycFJpWDhNckozdgphM0djREE4T0IxdTJLRFBXYmRyb0NHUFBUQjV5SktGTEZaSGxvL2xyb2JrRGNBeVFEUis0dDVndW5Ob3J5SzJhCkpIZEovNno3Z1lqYW1CWklJdXh2MTV3QWVyR3RvWFFKOUJrc2hEMENnWUEzODdaYmIzVmNQSEFjdUxhR2ZFejMKZ0xNeVEzRGV4Q3JlQVZUd2tPcTlzV09LaGZTcUhYeHNxVEN6Qnp5encwUnpkK0JWNEVrdmV1RkRCaVdnRTdrcApuZE0ySTZGdk5ybFErM1A3QmVZWWNRQnJNeVRMS3g1MmZGY05FSTNNUXVWajlHbG5JSjJld294bEZRemt1QjlwCml4bmIyMWx2L1dIMkpRVC9iTUdua3dLQmdCTXFVcEUwMUlTcXZlTTFsQlp1YUl1Qk5PQkxQOHFlS2tkbVV1bS8KSmxNZDErQnZZWlFTRmlKYjNTRWFRdlFaN0FzckFPbGQveGlpZGU0MTZGWm9VUzBwMVgwZFcxYmxzUlNpMDlNaQphTTdUUHpGOUF2MzlzZE9wYTBzSFN1WGxJTWgwcnFjcDZmUHhjWXdMTThBWFBhT3hoTy8wazhFdXN1Mzl5ZkRsCnM3bk5Bb0dBVEw5bndTZFc4WlY0Z1dNMzdjQnNISERVZ2Q5Zk5DQnpsbzFvM29HQjA2TmdLZGU0R0R2TC8rRU8KRG12bWNvNWQrNjdBZE1qUU9IRUM3ZFMwVWRwRHgyb2lJUTFaSGtjRlJnQ214eENZYWpPK1E1YmN1NmhZYUU4awp5bklwcTlTaE1QbCs4Q1BubHhIUlYxR2RJTm5QRXgrdkZ6aHNtaDEySzh4U210MkliVXM9Ci0tLS0tRU5EIFJTQSBQUklWQVRFIEtFWS0tLS0tCg==
#     project: YWRkb25z
#     type: Z2l0
#     url: aHR0cHM6Ly9naXRodWIuY29tL2JlYmV0LW9yZ2FuaXphdGlvbi9hd3MtZm91bmRhdGlvbi5naXQ=
#   EOF
# }

# resource "kubectl_manifest" "argocd_repo_aws_foundation" {
#   yaml_body = <<EOF
#   apiVersion: v1
#   kind: Secret
#   metadata:
#     name: repo-helm-charts
#     namespace: ${local.namespaces.devops}
#     labels:
#       argocd.argoproj.io/secret-type: repository
#     annotations:
#       managed-by: argocd.argoproj.io
#   type: Opaque
#   data:
#     githubAppID: OTcyNjQ2
#     githubAppInstallationID: NTM4NzEyNjM=
#     githubAppPrivateKey: >-
#       LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQpNSUlFb2dJQkFBS0NBUUVBOEhTVG1uZTBORTRhNlNOMVlzRndsZm1MSzRBR3pwdTVKTFU5Y2VVMDh0dithcGU3Cm1PY2xLaXlPSEltYTFmM0hCOVhxcDNnVWJKaTQvUXI2UldoVS82SFpiMUFkTFhrMGh3S0FrRm44NXh5enZBV2QKVWlXMmJVYnBuZFcxMHE5bUU0bXp2ZG1taW9tSmZwK1JiczVvL0lqNWt3Sk5lM2wrVy9YNXE0aC9uYTBqdGJ3dwpsckF0RnJSNWRtazhQOUpDNWY1L2Ywc0xMTWVXYUY4SWovTXFxSzh5N2kzZzhnWWNWNHQvT0hnRmtwSnRGYU4wCkJBTUxtbzY0OGR3ai8ycW90UnMwSFM3Q0lyUTQwUkNsV0lVaUxBTXM2QUNmbXVSdVhtazRkSW9YMW9Edlp6alUKSk5Gdk9KM2kvRm5wckRqZXpEem5PTXd0N1hOQnV1ZldqZGxYWndJREFRQUJBb0lCQUUxSm16djJKK1Q4Q2VoUAo3bVlzdVF4cnBsRDRHTGdHRTY5NTFlTXJBaWJoa1ZnZnB6dlJaLyt6VElaZHNIZ0IxeHhzcEx6cGV0OGhBNnpKCi80R1p0R0JxWEdKTUJPVGQ1WVZUeDVFZWE0eTVqQWZ1WWcvS2NXV1Vlbml4L1h4WHhsNlhUei9CbXFkQzUvL2MKT0RtK2ZMNVhKS2tjLzF5bHczaTVpbU9aUHpPbG1KbG1WMjVZcXVFbFgrWVRrYnhwWjJlTnRBWllTVkNLMkw3ego4WHJhYkFTOGdZamowYThOSldCMy9vZXpXUkZWWktmK2k3WHlJckFGdnV3NTNHbC9COFQxNkRjQlE4NnVKZEY3Ci82UENCMTM5MW9mR01ZT1VKNVhMaGlFaVc0ZDAvWjNKR09OUzZ4Y2xUNlZLaHh3dGdiZ3FPSWxDNTNvcm8vMlIKZ1MyTDFua0NnWUVBLzN0RklvdUcvc1FHRmIwc1JjRGk4UkM1akJQUmM2WTFBdnR1MlUrcE9JOXNZMFFqQi9teQpHRkpJcXZCamdjcSsyN1duOVFZc0h6LzBqQzRyenlkSGRRRCs2VTlQSGlDNGZZSDg4TkhGYnNOa0M3Rk90ejdVCllrcG5TNktwYTdsVDNMZUZXZnVnTElXS2RFZmc3UE9TRnJKUVIyL1dRSUp6bXI2bXhrS3dzSE1DZ1lFQThQR0EKQUZ6L1BScGw4aUFWQk1tdmRXZXZpVng1ZkpXNXArNEt0WUdaZWI4NTZYamEvcWhhTHlUQnVycFJpWDhNckozdgphM0djREE4T0IxdTJLRFBXYmRyb0NHUFBUQjV5SktGTEZaSGxvL2xyb2JrRGNBeVFEUis0dDVndW5Ob3J5SzJhCkpIZEovNno3Z1lqYW1CWklJdXh2MTV3QWVyR3RvWFFKOUJrc2hEMENnWUEzODdaYmIzVmNQSEFjdUxhR2ZFejMKZ0xNeVEzRGV4Q3JlQVZUd2tPcTlzV09LaGZTcUhYeHNxVEN6Qnp5encwUnpkK0JWNEVrdmV1RkRCaVdnRTdrcApuZE0ySTZGdk5ybFErM1A3QmVZWWNRQnJNeVRMS3g1MmZGY05FSTNNUXVWajlHbG5JSjJld294bEZRemt1QjlwCml4bmIyMWx2L1dIMkpRVC9iTUdua3dLQmdCTXFVcEUwMUlTcXZlTTFsQlp1YUl1Qk5PQkxQOHFlS2tkbVV1bS8KSmxNZDErQnZZWlFTRmlKYjNTRWFRdlFaN0FzckFPbGQveGlpZGU0MTZGWm9VUzBwMVgwZFcxYmxzUlNpMDlNaQphTTdUUHpGOUF2MzlzZE9wYTBzSFN1WGxJTWgwcnFjcDZmUHhjWXdMTThBWFBhT3hoTy8wazhFdXN1Mzl5ZkRsCnM3bk5Bb0dBVEw5bndTZFc4WlY0Z1dNMzdjQnNISERVZ2Q5Zk5DQnpsbzFvM29HQjA2TmdLZGU0R0R2TC8rRU8KRG12bWNvNWQrNjdBZE1qUU9IRUM3ZFMwVWRwRHgyb2lJUTFaSGtjRlJnQ214eENZYWpPK1E1YmN1NmhZYUU4awp5bklwcTlTaE1QbCs4Q1BubHhIUlYxR2RJTm5QRXgrdkZ6aHNtaDEySzh4U210MkliVXM9Ci0tLS0tRU5EIFJTQSBQUklWQVRFIEtFWS0tLS0tCg==
#     project: 
#     type: Z2l0
#     url: aHR0cHM6Ly9naXRodWIuY29tL2JlYmV0LW9yZ2FuaXphdGlvbi9oZWxtLWNoYXJ0cy5naXQ=
#   EOF
# }

# aeIfoAMuR27sdLLE