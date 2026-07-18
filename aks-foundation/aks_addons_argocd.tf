
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
%{if local.acr_argocd_pull_active~}
      # ADR-0021 gate 2: pull OCI Helm charts from the platform ACR with Azure
      # Workload Identity — the repo Secret below sets useAzureWorkloadIdentity
      # and the repo-server exchanges the projected token for an ACR pull token.
      # No registry credential is stored. Dormant until a chart is sourced from
      # ACR (Phase E); harmless while the umbrella is served from GHCR.
      serviceAccount:
        annotations:
          azure.workload.identity/client-id: "${try(azurerm_user_assigned_identity.acr_argocd_pull[0].client_id, "")}"
      podLabels:
        azure.workload.identity/use: "true"
      env:
        - name: AZURE_ARM_TOKEN_RESOURCE
          value: "https://containerregistry.azure.net"
%{endif~}

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
        # Health assessment for the platform's Crossplane composite resources.
        #
        # WHY THIS EXISTS: ArgoCD ships no health check for a custom group, and
        # it defaults unassessable kinds to Healthy. Without this, a
        # PostgresInstance that has not begun provisioning reports Healthy the
        # instant it is created, the infra sync-wave clears immediately, and the
        # app's migration wave runs against an Azure Flexible Server that will
        # not exist for another 5-10 minutes. The wave gate looks like it works
        # and does nothing.
        #
        # The wildcard covers PostgresInstance and RedisInstance both — every
        # Crossplane XR carries the same Ready/Synced condition contract, so one
        # script serves the whole group. Wildcards only work under the
        # `resource.customizations` key; the resource.customizations.health.
        # <group>_<kind> form does NOT support them.
        resource.customizations: |
          platform.myorg.io/*:
            health.lua: |
              local hs = {}
              hs.status = "Progressing"
              hs.message = "Waiting for the control plane to report status"

              if obj.status == nil or obj.status.conditions == nil then
                -- Freshly created: Crossplane has not written conditions yet.
                return hs
              end

              -- Synced=False means the Composition itself failed to reconcile
              -- (bad ProviderConfig, invalid spec, provider not installed).
              -- That is a real failure, not slow provisioning, so surface it
              -- rather than letting the wave hang until it times out.
              for _, c in ipairs(obj.status.conditions) do
                if c.type == "Synced" and c.status == "False" then
                  hs.status = "Degraded"
                  hs.message = c.reason or "ReconcileError"
                  if c.message ~= nil then
                    hs.message = hs.message .. ": " .. c.message
                  end
                  return hs
                end
              end

              -- Ready=True is Crossplane's statement that every composed
              -- resource is ready. For PostgresInstance that includes the
              -- composed connection Secret, which is patched from status.fqdn
              -- with policy Required — so it only exists once the server has a
              -- private FQDN. Ready therefore implies the host is knowable.
              for _, c in ipairs(obj.status.conditions) do
                if c.type == "Ready" then
                  if c.status == "True" then
                    hs.status = "Healthy"
                    hs.message = "Composed resources are ready"
                  else
                    hs.status = "Progressing"
                    hs.message = c.reason or "Creating"
                  end
                  return hs
                end
              end

              return hs
      params:
        application.namespaces: "*"  # Adding namespaces to be managed by ArgoCD

    EOT
  ]

  depends_on = [
    azurerm_kubernetes_cluster.main,
    helm_release.vault
  ]
}

resource "kubectl_manifest" "argocd_project_addons" {
  yaml_body  = <<-EOF
  apiVersion: argoproj.io/v1alpha1
  kind: AppProject
  metadata:
    name: addons-project
    namespace: ${local.namespaces.devops}
    # finalizers:
    #   - resources-finalizer.argocd.argoproj.io
  spec:
    description: Platform Project for AKS Addons
    clusterResourceWhitelist:
      - group: '*'
        kind: '*'
    destinations:
      - name: in-cluster
        server: https://kubernetes.default.svc
        namespace: '*'
    sourceRepos:
      - '*'
    sourceNamespaces:
      - '*'
    namespaceResourceWhitelist:
      - group: '*'
        kind: '*'
  EOF
  depends_on = [helm_release.argocd]
}

# resource "kubectl_manifest" "argocd_project_jarvix" {
#   yaml_body = <<EOF
#   apiVersion: argoproj.io/v1alpha1
#   kind: AppProject
#   metadata:
#     name: jarvix-project
#     namespace: ${local.namespaces.devops}
#   spec:
#     clusterResourceWhitelist:
#       - group: '*'
#         kind: '*'
#     destinations:
#       - namespace: '${local.namespaces.jarvix}'
#         server: '*'
#     sourceRepos:
#       - '*'
#   EOF
#   depends_on = [ helm_release.argocd ]
# }

################################################################################
# ArgoCD Repository - addons
################################################################################
resource "kubectl_manifest" "argocd_repo_addons" {
  yaml_body  = <<-EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: repo-addons
      namespace: ${local.namespaces.devops}
      labels:
        argocd.argoproj.io/secret-type: repository
      annotations:
        managed-by: argocd.argoproj.io
    type: Opaque
    stringData:
      type: git
      url: https://github.com/lurodrisilva/plat-eng-baseline-addons.git
  EOF
  depends_on = [helm_release.argocd]
}

################################################################################
# ArgoCD Repository - platform ACR (OCI Helm charts) — ADR-0021 gate 2
#
# Registers the platform ACR as an OCI Helm repository authenticated by the
# repo-server's Azure Workload Identity (uami-acr-argocd-pull, AcrPull) — no
# stored credential. The umbrella (ADR-0008) is still published to and served
# from GHCR today, so this repository holds no charts yet and ArgoCD does not
# resolve against it until an Application sources a chart from ACR (Phase E).
################################################################################
resource "kubectl_manifest" "argocd_repo_acr_charts" {
  count = local.acr_argocd_pull_active ? 1 : 0

  yaml_body  = <<-EOF
    apiVersion: v1
    kind: Secret
    metadata:
      name: repo-acr-platform-charts
      namespace: ${local.namespaces.devops}
      labels:
        argocd.argoproj.io/secret-type: repository
      annotations:
        managed-by: argocd.argoproj.io
    type: Opaque
    stringData:
      type: helm
      name: acr-platform-charts
      url: ${try(azurerm_container_registry.platform[0].login_server, "")}
      enableOCI: "true"
      useAzureWorkloadIdentity: "true"
  EOF
  depends_on = [helm_release.argocd]
}

################################################################################
# ArgoCD Application - addons
################################################################################
resource "kubectl_manifest" "argocd_app_addons" {
  yaml_body  = <<-EOF
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: baseline-addons
      namespace: ${local.namespaces.control_plane}
    spec:
      project: addons-project
      source:
        repoURL: https://github.com/lurodrisilva/plat-eng-baseline-addons.git
        targetRevision: HEAD
        path: base_chart
      destination:
        server: https://kubernetes.default.svc
        namespace: ${local.namespaces.control_plane}
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ApplyOutOfSyncOnly=true       # only apply out-of-sync resources
  EOF
  depends_on = [kubectl_manifest.argocd_repo_addons, kubectl_manifest.argocd_project_addons]
}
