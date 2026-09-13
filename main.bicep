// -----------------------------------------------------------------------------
// Deployment mode (cost preset)
//
// A single switch that flips every cost-relevant parameter at once:
//   CostOptimized (default) - minimum running cost for PoC / dev / demo.
//   Production              - the original, resiliency-oriented settings.
//
// Every value in the preset can still be overridden individually by passing the
// matching parameter explicitly ('' for strings, -1 for integers means "use the
// preset value").
// -----------------------------------------------------------------------------
@description('Cost preset applied to all cost-relevant parameters. CostOptimized minimises running cost (scale-to-zero, Spot nodes, locally-redundant storage); Production restores the resiliency-oriented defaults.')
@allowed([
  'CostOptimized'
  'Production'
])
param deploymentMode string = 'CostOptimized'

@description('Azure region for all resources. Must be a Discovery-supported region.')
@allowed([
  'eastus'
  'swedencentral'
  'uksouth'
])
param location string = 'swedencentral'

@description('Name of the Microsoft Discovery Supercomputer. Must be 3-24 characters, alphanumeric and hyphens only.')
@minLength(3)
@maxLength(24)
param supercomputerName string = 'sc-${uniqueString(resourceGroup().id)}'

@description('Name of the Node Pool created under the Supercomputer. Must be 1-12 lowercase alphanumeric characters, starting with a letter.')
@minLength(1)
@maxLength(12)
param nodePoolName string = 'nodepool1'

@description('Name of the Microsoft Discovery Workspace. Must be 3-24 characters, alphanumeric and hyphens only.')
@minLength(3)
@maxLength(24)
param workspaceName string = 'ws-${uniqueString(resourceGroup().id)}'

@description('Name of the Chat Model Deployment created under the Workspace.')
@minLength(3)
@maxLength(24)
param chatModelDeploymentName string = 'gpt-5-4'

@description('Name of the Microsoft Discovery Storage Container resource. Must be 3-24 characters, alphanumeric and hyphens only.')
@minLength(3)
@maxLength(24)
param storageContainerName string = 'stc-${uniqueString(resourceGroup().id)}'

@description('Name of the Project created under the Workspace. Must be 3-24 characters, alphanumeric and hyphens only.')
@minLength(3)
@maxLength(24)
param projectName string = 'prj-${uniqueString(resourceGroup().id)}'

@description('Name of the Virtual Network. Must be 2-64 characters: letters, numbers, underscores, periods, or hyphens; must start with a letter or number and end with a letter, number, or underscore.')
@minLength(2)
@maxLength(64)
param vnetName string = 'discovery-vnet'

@description('Name of the User-Assigned Managed Identity.')
param managedIdentityName string = 'uami-${uniqueString(resourceGroup().id)}'

@description('Globally unique name of the Azure Storage Account (3-24 lowercase alphanumeric characters).')
@minLength(3)
@maxLength(24)
param storageAccountName string = 'stg${uniqueString(resourceGroup().id)}'

@description('Name of the blob container inside the Storage Account used for Discovery outputs.')
param blobContainerName string = 'discoveryoutputs'

@description('Replication SKU for the Storage Account. Leave empty to use the deploymentMode preset (CostOptimized: Standard_LRS, Production: Standard_GRS).')
@allowed([
  ''
  'Standard_LRS'
  'Standard_ZRS'
  'Standard_GRS'
  'Standard_GZRS'
  'Standard_RAGRS'
  'Standard_RAGZRS'
])
param storageAccountSku string = ''

@description('Access tier for the Storage Account. Leave empty to use the deploymentMode preset (CostOptimized: Cool, Production: Hot).')
@allowed([
  ''
  'Hot'
  'Cool'
])
param storageAccessTier string = ''

@description('Address space for the Virtual Network.')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Address prefix for the Supercomputer Node Pool subnet.')
param supercomputerNodepoolSubnetPrefix string = '10.0.1.0/24'

@description('Address prefix for the AKS system subnet used by the Supercomputer.')
param aksSubnetPrefix string = '10.0.2.0/24'

@description('Address prefix for the Workspace subnet (delegated to Microsoft.App/environments).')
param workspaceSubnetPrefix string = '10.0.3.0/24'

@description('Address prefix for the Private Endpoint subnet.')
param privateEndpointSubnetPrefix string = '10.0.4.0/24'

@description('Address prefix for the Agent subnet.')
param agentSubnetPrefix string = '10.0.5.0/24'

@description('Address prefix for Search Subnet.')
param searchSubnetPrefix string = '10.0.6.0/24'

// The Bookshelf managed AI Search instance needs its own, non-delegated subnet
// that is distinct from the private endpoint subnet.
@description('Address prefix for the Bookshelf Search subnet (must differ from the Private Endpoint subnet).')
param bookshelfSearchSubnetPrefix string = '10.0.7.0/24'

@description('VM SKU for the Node Pool. Leave empty to use the deploymentMode preset (Standard_D4s_v6 in both modes).')
param nodePoolVmSize string = ''

@description('Maximum number of nodes in the Node Pool. Use -1 to apply the deploymentMode preset (CostOptimized: 1, Production: 3).')
@minValue(-1)
param nodePoolMaxNodeCount int = -1

@description('Minimum number of nodes in the Node Pool (0 allows scale-to-zero). Use -1 to apply the deploymentMode preset (0 in both modes).')
@minValue(-1)
param nodePoolMinNodeCount int = -1

@description('Scale set priority for the Node Pool. Leave empty to use the deploymentMode preset (CostOptimized: Spot, Production: Regular).')
@allowed([
  ''
  'Regular'
  'Spot'
])
param nodePoolScaleSetPriority string = ''

@description('OS disk size (GB) for the Node Pool nodes. Use -1 to apply the deploymentMode preset (CostOptimized: 64, Production: 120).')
@minValue(-1)
@maxValue(2048)
param nodePoolOsDiskSizeGb int = -1

@description('VM SKU of the AKS system node pool managed by the Supercomputer. Leave empty to use the deploymentMode preset (Standard_D4s_v6 in both modes).')
@allowed([
  ''
  'Standard_D4s_v4'
  'Standard_D4s_v5'
  'Standard_D4s_v6'
])
param supercomputerSystemSku string = ''

@description('Chat model format.')
param chatModelFormat string = 'OpenAI'

@description('Chat model name to deploy.')
param chatModelName string = 'gpt-5.4'

@description('Enable GitHub Copilot and AI features in the Discovery workspace via the discovery.workbench.enableGhcpAiFeatures tag.')
param enableGhcpAiFeatures bool = true

@description('Enable the VS Code Extension Marketplace in the Discovery workspace via the discovery.workbench.enableExtensions tag.')
param enableExtensions bool = true

@description('Workspace network isolation mode via the NetworkIsolation tag. Set to false to enable public preview access as documented in the Infrastructure portal quickstart.')
param networkIsolation bool = true

// -----------------------------------------------------------------------------
// Discovery control-plane first-party service principal.
//
// Discovery workspaces / bookshelves / supercomputers are network-hardened by
// default and require the control-plane app to configure a Network Security
// Perimeter (NSP) in your subscription. The app cannot do that unless it holds
// both the custom "Discovery NSP Perimeter Joiner" role and the built-in
// "Reader" role at subscription scope.
//
// Docs:
//   https://learn.microsoft.com/en-us/azure/microsoft-discovery/quickstart-infrastructure-portal#b-assign-required-roles-to-discovery-control-plane-service-app
//   https://learn.microsoft.com/en-us/azure/microsoft-discovery/how-to-configure-network-security?tabs=azure-cli
//
// The Application (client) ID of the first-party app is fixed:
//   92c174ac-8e41-4815-a1b7-d81b19ab03ce
// but role assignments require the Object ID (the service principal's id in
// the current tenant). Look it up before deploying:
//   az ad sp show --id 92c174ac-8e41-4815-a1b7-d81b19ab03ce --query id -o tsv
// -----------------------------------------------------------------------------
@description('Object ID (not App ID) of the Discovery control-plane first-party service principal in the current tenant. Resolve with: az ad sp show --id 92c174ac-8e41-4815-a1b7-d81b19ab03ce --query id -o tsv')
param discoveryControlPlanePrincipalId string

// -----------------------------------------------------------------------------
// Discovery Studio (data-plane) administrators.
//
// The Microsoft Discovery workspace ships with its OWN data-plane RBAC that is
// completely separate from ARM Owner / Contributor. Without a Discovery-scoped
// role, users signing in to https://studio.discovery.microsoft.com see
// "Access denied. Ensure you have the correct role assigned on this workspace
// resource in the Azure portal." when trying to create Agents/Projects — even
// when they hold Owner on the subscription.
//
// This template assigns "Microsoft Discovery Platform Administrator (Preview)"
// (roleId 7a2b6e6c-472e-4b39-8878-a26eb63d75c6) at the resource group scope,
// which grants Microsoft.Discovery/* on all Discovery resources in the RG
// (workspaces, storageContainers, supercomputers, and their children).
//
// Pass one or more Entra Object IDs; typically populated from
//   az ad signed-in-user show --query id -o tsv
// by the deploy wrapper script.
// -----------------------------------------------------------------------------
@description('Object IDs of Entra principals to grant "Microsoft Discovery Platform Administrator (Preview)" on this resource group. Enables Discovery Studio operations (create Agents/Projects/etc.). Leave empty to skip.')
param workspaceAdminPrincipalIds array = []

@description('Principal type for workspaceAdminPrincipalIds. Use User for individual accounts, Group for Entra security groups, ServicePrincipal for apps.')
@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
param workspaceAdminPrincipalType string = 'User'

// -----------------------------------------------------------------------------
// Bookshelf (Knowledge Base host).
//
// A Knowledge Base cannot exist on its own: it always lives inside a Bookshelf
// control-plane resource. Creating the Bookshelf provisions its own managed
// resource group containing Azure SQL, AI Search, Container Apps and Storage,
// so it is the single most expensive optional component of this template.
// Set deployBookshelf=false to skip the whole Knowledge stack.
//
// The Knowledge Base itself (and its indexing run) is a data-plane object that
// is created from Discovery Studio -> Resources -> Knowledge, not from ARM.
// This template provisions everything that Studio asks you to pick in that
// wizard: the Bookshelf, the workload identity, the source blob container, the
// Discovery storage container and the storage asset.
//
// Docs: https://learn.microsoft.com/azure/microsoft-discovery/how-to-index-bookshelf-knowledgebase
// -----------------------------------------------------------------------------
@description('Deploy the Bookshelf and the Knowledge Base source storage (blob container, Discovery storage container, storage asset, workload identity). Set to false to skip the Knowledge stack entirely.')
param deployBookshelf bool = true

@description('Name of the Microsoft Discovery Bookshelf. Becomes part of the data-plane endpoint https://<name>.bookshelf.discovery.azure.com.')
@minLength(3)
@maxLength(24)
param bookshelfName string = 'bks-${uniqueString(resourceGroup().id)}'

@description('Name of the User-Assigned Managed Identity used by the Bookshelf knowledgebase workloads to read the source documents.')
param bookshelfIdentityName string = 'uami-bks-${uniqueString(resourceGroup().id)}'

@description('Bookshelf indexSize tag. Controls the compute provisioned in the Bookshelf managed resource group. Leave empty to use the deploymentMode preset (CostOptimized: small, Production: medium).')
@allowed([
  ''
  'small'
  'medium'
  'large'
])
param bookshelfIndexSize string = ''

@description('Public network access for the Bookshelf data-plane endpoint. Leave empty to derive it from networkIsolation (true -> Disabled, false -> Enabled).')
@allowed([
  ''
  'Enabled'
  'Disabled'
])
param bookshelfPublicNetworkAccess string = ''

@description('Name of the subnet used by the Bookshelf managed AI Search instance. Must not be the private endpoint subnet.')
param bookshelfSearchSubnetName string = 'bookshelfSearchSubnet'

@description('Name of the blob container that holds the source documents indexed into the Knowledge Base.')
param knowledgeBlobContainerName string = 'knowledgedocuments'

@description('Name of the Microsoft Discovery Storage Container resource that exposes the knowledge documents to Discovery.')
@minLength(3)
@maxLength(24)
param knowledgeStorageContainerName string = 'kstc-${uniqueString(resourceGroup().id)}'

@description('Name of the Storage Asset that points at the knowledge documents inside the storage container.')
@minLength(3)
@maxLength(24)
param knowledgeStorageAssetName string = 'kasset-${uniqueString(resourceGroup().id)}'

@description('Path of the knowledge documents relative to the storage account root. Leave empty to use "<knowledgeBlobContainerName>/".')
param knowledgeStorageAssetPath string = ''

@description('Description shown in Discovery Studio for the knowledge storage asset.')
param knowledgeStorageAssetDescription string = 'Source documents indexed into the Bookshelf Knowledge Base.'

// -----------------------------------------------------------------------------
// Discovery Tools.
//
// Microsoft.Discovery/tools is a first-class ARM resource: a tool is a JSON
// definition (id, name, description and a list of actions with their input
// schema and command) that Discovery Studio then offers in the "Tools" section
// of the agent creation form. Studio can only *select* tools, so they have to
// be created here.
//
// Docs: https://learn.microsoft.com/rest/api/discovery/tools/create-or-update
// -----------------------------------------------------------------------------
@description('Deploy the Microsoft.Discovery/tools resources listed in the tools parameter.')
param deployTools bool = true

@description('Tool definitions to create. Each item needs name, version and definitionContent; environmentVariables is optional and is merged with the template-wide tool environment. Leave empty to deploy the built-in sample tool.')
param tools array = []

@description('Extra environment variables merged into every deployed tool, on top of the template-managed DISCOVERY_* values.')
param toolEnvironmentVariables object = {}


// -----------------------------------------------------------------------------
// Cost presets
//
// modePresets holds one parameter set per deploymentMode. Changing the single
// `deploymentMode` parameter flips every value below at once. Any individual
// parameter that is explicitly supplied (non-empty string / non-negative int)
// wins over the preset.
// -----------------------------------------------------------------------------
var modePresets = {
  CostOptimized: {
    // Node pool: scale-to-zero, a single Spot node at most and a small OS disk.
    nodePoolVmSize: 'Standard_D4s_v6'
    nodePoolMaxNodeCount: 1
    nodePoolMinNodeCount: 0
    nodePoolScaleSetPriority: 'Spot'
    nodePoolOsDiskSizeGb: 64
    // AKS system node pool managed by the Supercomputer. Discovery only accepts
    // Standard_D4s_v4 / v5 / v6 (all 4 vCPU), so there is no cheaper option.
    supercomputerSystemSku: 'Standard_D4s_v6'
    // Storage: locally-redundant + cool tier is the cheapest durable option.
    storageAccountSku: 'Standard_LRS'
    storageAccessTier: 'Cool'
    // Bookshelf: the smallest index sizes the least expensive AI Search / SQL /
    // Container Apps footprint in the Bookshelf managed resource group.
    bookshelfIndexSize: 'small'
  }
  Production: {
    nodePoolVmSize: 'Standard_D4s_v6'
    nodePoolMaxNodeCount: 3
    nodePoolMinNodeCount: 0
    nodePoolScaleSetPriority: 'Regular'
    nodePoolOsDiskSizeGb: 120
    supercomputerSystemSku: 'Standard_D4s_v6'
    storageAccountSku: 'Standard_GRS'
    storageAccessTier: 'Hot'
    bookshelfIndexSize: 'medium'
  }
}

var preset = modePresets[deploymentMode]

var effectiveNodePoolVmSize = empty(nodePoolVmSize) ? preset.nodePoolVmSize : nodePoolVmSize
var effectiveNodePoolMaxNodeCount = nodePoolMaxNodeCount < 0 ? preset.nodePoolMaxNodeCount : nodePoolMaxNodeCount
var effectiveNodePoolMinNodeCount = nodePoolMinNodeCount < 0 ? preset.nodePoolMinNodeCount : nodePoolMinNodeCount
var effectiveNodePoolScaleSetPriority = empty(nodePoolScaleSetPriority)
  ? preset.nodePoolScaleSetPriority
  : nodePoolScaleSetPriority
var effectiveNodePoolOsDiskSizeGb = nodePoolOsDiskSizeGb < 0 ? preset.nodePoolOsDiskSizeGb : nodePoolOsDiskSizeGb
var effectiveSupercomputerSystemSku = empty(supercomputerSystemSku)
  ? preset.supercomputerSystemSku
  : supercomputerSystemSku
var effectiveStorageAccountSku = empty(storageAccountSku) ? preset.storageAccountSku : storageAccountSku
var effectiveStorageAccessTier = empty(storageAccessTier) ? preset.storageAccessTier : storageAccessTier

var effectiveBookshelfIndexSize = empty(bookshelfIndexSize) ? preset.bookshelfIndexSize : bookshelfIndexSize
var effectiveBookshelfPublicNetworkAccess = empty(bookshelfPublicNetworkAccess)
  ? (networkIsolation ? 'Disabled' : 'Enabled')
  : bookshelfPublicNetworkAccess
var effectiveKnowledgeStorageAssetPath = empty(knowledgeStorageAssetPath)
  ? '${knowledgeBlobContainerName}/'
  : knowledgeStorageAssetPath

// Sample tool used when the caller does not supply its own definitions. It runs
// on the node pool created by this template and writes into the project's
// storage container, so it works out of the box in both deployment modes.
var defaultTools = [
  {
    name: 'dataset-summary'
    version: '1.0.0'
    definitionContent: {
      tool_id: 'dataset-summary'
      name: 'DatasetSummary'
      description: 'Summarises tabular datasets (CSV/TSV) that were mounted into the tool container and writes a markdown report.'
      actions: [
        {
          name: 'SummarizeDataset'
          description: 'Reads every CSV/TSV file under the input mount (/app/inputs) and writes summary.md plus summary.json to the output mount (/app/outputs). Mount the dataset to /app/inputs and capture /app/outputs.'
          input_schema: {
            type: 'object'
            properties: {
              inputPath: {
                type: 'string'
                description: 'Absolute path inside the container that the dataset is mounted to. Defaults to /app/inputs.'
              }
              outputPath: {
                type: 'string'
                description: 'Absolute path inside the container that the report is written to. Defaults to /app/outputs.'
              }
              maxRows: {
                type: 'string'
                description: 'Maximum number of rows to read per file. Keep this small in CostOptimized deployments.'
              }
            }
            required: [
              'inputPath'
            ]
          }
          command: 'python3 -m discovery_tools.dataset_summary'
          environment_variables: [
            {
              name: 'INPUT_DIRECTORY_PATH'
              value: '{{ inputPath }}'
            }
            {
              name: 'OUTPUT_DIRECTORY_PATH'
              value: '{{ outputPath }}'
            }
            {
              name: 'MAX_ROWS'
              value: '{{ maxRows }}'
            }
          ]
        }
      ]
    }
  }
]

var effectiveTools = empty(tools) ? defaultTools : tools

// Environment variables handed to every tool so the tool command can adapt to
// the deployment mode without hard-coding infrastructure details. The
// parallelism hint tracks the node pool maximum, which is the cost-mode knob.
var managedToolEnvironmentVariables = {
  DISCOVERY_DEPLOYMENT_MODE: deploymentMode
  DISCOVERY_NODE_POOL_NAME: nodePoolName
  DISCOVERY_STORAGE_CONTAINER_NAME: storageContainerName
  DISCOVERY_MAX_PARALLELISM: string(effectiveNodePoolMaxNodeCount)
}

var effectiveToolEnvironmentVariables = union(managedToolEnvironmentVariables, toolEnvironmentVariables)

// Tags applied to every taggable resource created by this template.
var commonTags = {
  SecurityControl: 'Ignore'
}

// Built-in role definition IDs
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var discoveryPlatformContributorRoleId = '01288891-85ee-45a7-b367-9db3b752fc65'
var discoveryPlatformAdministratorRoleId = '7a2b6e6c-472e-4b39-8878-a26eb63d75c6'
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

// Subscription-scoped module: create the "Discovery NSP Perimeter Joiner"
// custom role and grant NSP Perimeter Joiner + Reader to the Discovery
// control-plane service principal. This must complete before any
// Microsoft.Discovery/* resource is created, otherwise the control plane
// fails to provision the auto-generated NetworkSecurityPerimeter and the
// deployment returns InternalServerError from the NSP resource.
// Deployment name includes the region so this template can be redeployed
// in different regions of the same subscription without hitting the
// "InvalidDeploymentLocation" error (subscription-scope deployments are
// locked to a single location per deployment name). All underlying
// resources are GUID-based and idempotent.
module discoveryControlPlaneRoles 'subscription-roles.bicep' = {
  name: 'discoveryControlPlaneRoles-${location}'
  scope: subscription()
  params: {
    discoveryControlPlanePrincipalId: discoveryControlPlanePrincipalId
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: commonTags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'supercomputerNodepoolSubnet'
        properties: {
          addressPrefix: supercomputerNodepoolSubnetPrefix
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
            }
          ]
        }
      }
      {
        name: 'aksSubnet'
        properties: {
          addressPrefix: aksSubnetPrefix
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
            }
          ]
        }
      }
      {
        name: 'workspaceSubnet'
        properties: {
          addressPrefix: workspaceSubnetPrefix
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
            }
          ]
        }
      }
      {
        name: 'privateEndpointSubnet'
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
        }
      }
      {
        name: 'agentSubnet'
        properties: {
          addressPrefix: agentSubnetPrefix
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
            }
          ]
        }
      }
      {
        name: 'searchSubnet'
        properties: {
          addressPrefix: searchSubnetPrefix
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
            }
          ]
        }
      }
      {
        // Left undelegated on purpose: the Bookshelf managed AI Search instance
        // cannot join a subnet delegated to Microsoft.App/environments.
        name: bookshelfSearchSubnetName
        properties: {
          addressPrefix: bookshelfSearchSubnetPrefix
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
            }
          ]
        }
      }
    ]
  }
}

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: managedIdentityName
  location: location
  tags: commonTags
  properties: {
    isolationScope: 'Regional'
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: commonTags
  kind: 'StorageV2'
  sku: {
    name: effectiveStorageAccountSku
  }
  dependsOn: [
    vnet
  ]
  properties: {
    accessTier: effectiveStorageAccessTier
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    // NOTE: defaultAction is intentionally 'Allow'. 
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
      virtualNetworkRules: [
        {
          id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'supercomputerNodepoolSubnet')
          action: 'Allow'
        }
        {
          id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'aksSubnet')
          action: 'Allow'
        }
        {
          id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'workspaceSubnet')
          action: 'Allow'
        }
        {
          id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'agentSubnet')
          action: 'Allow'
        }
        {
          id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'searchSubnet')
          action: 'Allow'
        }
        {
          id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, bookshelfSearchSubnetName)
          action: 'Allow'
        }
      ]
    }
  }
}

resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    cors: {
      corsRules: [
        {
          allowedOrigins: [
            'https://studio.discovery.microsoft.com'
            'https://*.vscode-cdn.net'
            'https://vscode.dev'
          ]
          allowedMethods: [
            'GET'
            'HEAD'
            'DELETE'
            'PUT'
          ]
          allowedHeaders: [
            '*'
          ]
          exposedHeaders: [
            '*'
          ]
          maxAgeInSeconds: 200
        }
      ]
    }
  }
}

resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobServices
  name: blobContainerName
  properties: {
    publicAccess: 'None'
  }
}

// Kept separate from the Discovery output container so that agent/tool results
// never end up in the corpus that the Knowledge Base indexes.
resource knowledgeBlobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = if (deployBookshelf) {
  parent: blobServices
  name: knowledgeBlobContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource storageBlobDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, managedIdentity.id, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource discoveryPlatformContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, managedIdentity.id, discoveryPlatformContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      discoveryPlatformContributorRoleId
    )
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource acrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, managedIdentity.id, acrPullRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Grants Discovery Studio (data-plane) access at RG scope. Required so the
// signed-in user can create Agents / Projects / etc. after deployment
// without a manual "az role assignment create" step.
resource discoveryStudioAdminAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in workspaceAdminPrincipalIds: {
    name: guid(resourceGroup().id, principalId, discoveryPlatformAdministratorRoleId)
    properties: {
      roleDefinitionId: subscriptionResourceId(
        'Microsoft.Authorization/roleDefinitions',
        discoveryPlatformAdministratorRoleId
      )
      principalId: principalId
      principalType: workspaceAdminPrincipalType
    }
  }
]

resource supercomputer 'Microsoft.Discovery/supercomputers@2026-06-01' = {
  name: supercomputerName
  location: location
  tags: union(commonTags, {
    version: 'v2'
  })
  dependsOn: [
    vnet
    // Roles must exist before the control plane configures NSP.
    discoveryControlPlaneRoles
  ]
  properties: {
    subnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'aksSubnet')
    systemSku: effectiveSupercomputerSystemSku
    identities: {
      clusterIdentity: {
        id: managedIdentity.id
      }
      kubeletIdentity: {
        id: managedIdentity.id
      }
      workloadIdentities: {
        '${managedIdentity.id}': {}
      }
    }
  }
}

resource nodePool 'Microsoft.Discovery/supercomputers/nodePools@2026-06-01' = {
  parent: supercomputer
  name: nodePoolName
  location: location
  tags: commonTags
  dependsOn: [
    vnet
  ]
  properties: {
    subnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'supercomputerNodepoolSubnet')
    vmSize: effectiveNodePoolVmSize
    maxNodeCount: effectiveNodePoolMaxNodeCount
    minNodeCount: effectiveNodePoolMinNodeCount
    scaleSetPriority: effectiveNodePoolScaleSetPriority
    osDiskSizeGb: effectiveNodePoolOsDiskSizeGb
  }
}

resource workspace 'Microsoft.Discovery/workspaces@2026-06-01' = {
  name: workspaceName
  location: location
  tags: union(commonTags, {
    version: 'v2'
    'discovery.workbench.enableGhcpAiFeatures': string(enableGhcpAiFeatures)
    'discovery.workbench.enableExtensions': string(enableExtensions)
    NetworkIsolation: string(networkIsolation)
  })
  dependsOn: [
    vnet
    nodePool
    // Roles must exist before the control plane configures NSP.
    discoveryControlPlaneRoles
  ]
  properties: {
    workspaceIdentity: {
      id: managedIdentity.id
    }
    supercomputerIds: [
      supercomputer.id
    ]
    agentSubnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'agentSubnet')
    privateEndpointSubnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'privateEndpointSubnet')
    workspaceSubnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'workspaceSubnet')
  }
}

resource chatModelDeployment 'Microsoft.Discovery/workspaces/chatModelDeployments@2026-06-01' = {
  parent: workspace
  name: chatModelDeploymentName
  location: location
  tags: commonTags
  properties: {
    modelFormat: chatModelFormat
    modelName: chatModelName
  }
}

resource discoveryStorageContainer 'Microsoft.Discovery/storageContainers@2026-06-01' = {
  name: storageContainerName
  location: location
  tags: commonTags
  dependsOn: [
    // Roles must exist before the control plane configures NSP.
    discoveryControlPlaneRoles
  ]
  properties: {
    storageStore: {
      kind: 'AzureStorageBlob'
      storageAccountId: storageAccount.id
    }
  }
}

resource project 'Microsoft.Discovery/workspaces/projects@2026-06-01' = {
  parent: workspace
  name: projectName
  location: location
  tags: commonTags
  dependsOn: [
    chatModelDeployment
  ]
  properties: {
    storageContainerIds: [
      discoveryStorageContainer.id
    ]
  }
}

// -----------------------------------------------------------------------------
// Bookshelf stack (optional, controlled by deployBookshelf)
// -----------------------------------------------------------------------------

// Dedicated identity so the Bookshelf's blob access can be revoked without
// touching the Supercomputer/Workspace identity.
resource bookshelfIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = if (deployBookshelf) {
  name: bookshelfIdentityName
  location: location
  tags: commonTags
  properties: {
    isolationScope: 'Regional'
  }
}

resource bookshelfStorageBlobDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployBookshelf) {
  name: guid(storageAccount.id, bookshelfIdentityName, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: bookshelfIdentity!.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource bookshelf 'Microsoft.Discovery/bookshelves@2026-06-01' = if (deployBookshelf) {
  name: bookshelfName
  location: location
  tags: union(commonTags, {
    indexSize: effectiveBookshelfIndexSize
  })
  dependsOn: [
    vnet
    // Roles must exist before the control plane configures NSP.
    discoveryControlPlaneRoles
  ]
  properties: {
    customerManagedKeys: 'Disabled'
    publicNetworkAccess: effectiveBookshelfPublicNetworkAccess
    privateEndpointSubnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'privateEndpointSubnet')
    searchSubnetId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, bookshelfSearchSubnetName)
    workloadIdentities: {
      '${bookshelfIdentity!.id}': {}
    }
  }
}

resource knowledgeStorageContainer 'Microsoft.Discovery/storageContainers@2026-06-01' = if (deployBookshelf) {
  name: knowledgeStorageContainerName
  location: location
  tags: commonTags
  dependsOn: [
    knowledgeBlobContainer
    discoveryControlPlaneRoles
  ]
  properties: {
    storageStore: {
      kind: 'AzureStorageBlob'
      storageAccountId: storageAccount.id
    }
  }
}

resource knowledgeStorageAsset 'Microsoft.Discovery/storageContainers/storageAssets@2026-06-01' = if (deployBookshelf) {
  parent: knowledgeStorageContainer
  name: knowledgeStorageAssetName
  location: location
  tags: commonTags
  properties: {
    description: knowledgeStorageAssetDescription
    path: effectiveKnowledgeStorageAssetPath
  }
}

// -----------------------------------------------------------------------------
// Discovery Tools (optional, controlled by deployTools)
// -----------------------------------------------------------------------------
resource discoveryTools 'Microsoft.Discovery/tools@2026-06-01' = [
  for tool in (deployTools ? effectiveTools : []): {
    name: tool.name
    location: location
    tags: commonTags
    dependsOn: [
      discoveryControlPlaneRoles
    ]
    properties: {
      version: tool.version
      definitionContent: tool.definitionContent
      environmentVariables: union(effectiveToolEnvironmentVariables, tool.?environmentVariables ?? {})
    }
  }
]

@description('Resource ID of the Supercomputer.')
output supercomputerId string = supercomputer.id

@description('Resource ID of the Node Pool.')
output nodePoolId string = nodePool.id

@description('Resource ID of the Workspace.')
output workspaceId string = workspace.id

@description('Resource ID of the Chat Model Deployment.')
output chatModelDeploymentId string = chatModelDeployment.id

@description('Resource ID of the Discovery Storage Container.')
output storageContainerId string = discoveryStorageContainer.id

@description('Resource ID of the Project.')
output projectId string = project.id

@description('Resource ID of the User-Assigned Managed Identity.')
output managedIdentityId string = managedIdentity.id

@description('Resource ID of the Storage Account.')
output storageAccountId string = storageAccount.id

@description('Resource ID of the Virtual Network.')
output vnetId string = vnet.id

@description('Resource ID of the Bookshelf, or empty when deployBookshelf is false.')
output bookshelfId string = deployBookshelf ? bookshelf!.id : ''

@description('Data-plane endpoint of the Bookshelf, or empty when deployBookshelf is false.')
output bookshelfEndpoint string = deployBookshelf ? 'https://${bookshelfName}.bookshelf.discovery.azure.com' : ''

@description('Resource ID of the Bookshelf workload identity. Select this identity in the Create knowledge base wizard.')
output bookshelfIdentityId string = deployBookshelf ? bookshelfIdentity!.id : ''

@description('Resource ID of the Discovery Storage Container that exposes the knowledge documents.')
output knowledgeStorageContainerId string = deployBookshelf ? knowledgeStorageContainer!.id : ''

@description('Resource ID of the Storage Asset to select in the Create knowledge base wizard.')
output knowledgeStorageAssetId string = deployBookshelf ? knowledgeStorageAsset!.id : ''

@description('Blob container that the Knowledge Base indexes. Upload the source documents here.')
output knowledgeBlobContainer string = deployBookshelf ? knowledgeBlobContainerName : ''

@description('Names of the deployed Microsoft.Discovery/tools resources.')
output toolNames array = [for tool in (deployTools ? effectiveTools : []): tool.name]

@description('Cost preset applied to this deployment.')
output deploymentModeApplied string = deploymentMode

@description('Cost-relevant settings actually applied (after preset + explicit overrides).')
output effectiveCostSettings object = {
  nodePoolVmSize: effectiveNodePoolVmSize
  nodePoolMaxNodeCount: effectiveNodePoolMaxNodeCount
  nodePoolMinNodeCount: effectiveNodePoolMinNodeCount
  nodePoolScaleSetPriority: effectiveNodePoolScaleSetPriority
  nodePoolOsDiskSizeGb: effectiveNodePoolOsDiskSizeGb
  supercomputerSystemSku: effectiveSupercomputerSystemSku
  storageAccountSku: effectiveStorageAccountSku
  storageAccessTier: effectiveStorageAccessTier
  bookshelfDeployed: deployBookshelf
  bookshelfIndexSize: deployBookshelf ? effectiveBookshelfIndexSize : 'n/a'
  bookshelfPublicNetworkAccess: deployBookshelf ? effectiveBookshelfPublicNetworkAccess : 'n/a'
  toolsDeployed: deployTools ? length(effectiveTools) : 0
  toolMaxParallelism: string(effectiveNodePoolMaxNodeCount)
}
