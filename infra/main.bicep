targetScope = 'resourceGroup'

@minLength(1)
@maxLength(64)
@description('Name of the the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
@allowed(['australiaeast', 'eastasia','eastus', 'eastus2', 'northeurope', 'southcentralus', 'southeastasia', 'uksouth', 'westus2'])
@metadata({
  azd: {
    type: 'location'
  }
})
param location string
param skipVnet bool = true
param apiServiceName string = ''
param apiUserAssignedIdentityName string = ''
param applicationInsightsName string = ''
param appServicePlanName string = ''
param logAnalyticsName string = ''
// param resourceGroupName string = ''
param storageAccountName string = ''
param vNetName string = ''
param disableLocalAuth bool = true

// @allowed([ 'consumption', 'flexconsumption' ])
// param azFunctionHostingPlanType string = 'flexconsumption'

param openAiServiceName string = ''
 
param openAiSkuName string
@allowed([ 'azure', 'openai', 'azure_custom' ])
param openAiHost string // Set in main.parameters.json
param openAiApiVersion string = '2023-05-15'

param chatGptModelName string = ''
param chatGptDeploymentName string = ''
param chatGptDeploymentVersion string = ''
param chatGptDeploymentCapacity int = 0

var chatGpt = {
  modelName: !empty(chatGptModelName) ? chatGptModelName : startsWith(openAiHost, 'azure') ? 'gpt-35-turbo' : 'gpt-3.5-turbo'
  deploymentName: !empty(chatGptDeploymentName) ? chatGptDeploymentName : 'chat'
  deploymentVersion: !empty(chatGptDeploymentVersion) ? chatGptDeploymentVersion : '0125'
  deploymentCapacity: chatGptDeploymentCapacity != 0 ? chatGptDeploymentCapacity : 40
}

@description('Id of the user or app to assign application roles')
param principalId string = ''

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(resourceGroup().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }
var functionAppName = !empty(apiServiceName) ? apiServiceName : '${abbrs.webSitesFunctions}api-${resourceToken}'
var deploymentStorageContainerName = 'app-package-${take(functionAppName, 32)}-${take(toLower(uniqueString(functionAppName, resourceToken)), 7)}'


// User assigned managed identity to be used by the function app to reach storage and service bus
module apiUserAssignedIdentity './core/identity/userAssignedIdentity.bicep' = {
  name: 'apiUserAssignedIdentity'
  
  params: {
    location: location
    tags: tags
    identityName: !empty(apiUserAssignedIdentityName) ? apiUserAssignedIdentityName : '${abbrs.managedIdentityUserAssignedIdentities}api-${resourceToken}'
  }
}

// The application backend is a function app
module appServicePlan './core/host/appserviceplan.bicep' = {
  name: 'appserviceplan'
  
  params: {
    name: !empty(appServicePlanName) ? appServicePlanName : '${abbrs.webServerFarms}${resourceToken}'
    location: location
    tags: tags
    sku: {
      name: 'FC1'
      tier: 'FlexConsumption'
    }
  }
}

module api './app/api.bicep' = {
  name: 'api'
  
  params: {
    name: functionAppName
    location: location
    tags: tags
    applicationInsightsName: monitoring.outputs.applicationInsightsName
    appServicePlanId: appServicePlan.outputs.id
    runtimeName: 'python'
    runtimeVersion: '3.11'
    storageAccountName: storage.outputs.name
    deploymentStorageContainerName: deploymentStorageContainerName
    identityId: apiUserAssignedIdentity.outputs.identityId
    identityClientId: apiUserAssignedIdentity.outputs.identityClientId
    appSettings: {
      OPENAI_API_VERSION: openAiApiVersion
      AZURE_OPENAI_CHATGPT_MODEL: chatGpt.modelName
    }
    virtualNetworkSubnetId: skipVnet ? '' : serviceVirtualNetwork.outputs.appSubnetID
    aiServiceUrl: ai.outputs.endpoint
  }
}

module ai 'core/ai/openai.bicep' = {
  name: 'openai'
  
  params: {
    name: !empty(openAiServiceName) ? openAiServiceName : '${abbrs.cognitiveServicesAccounts}${resourceToken}'
    location: location
    tags: tags
    publicNetworkAccess: skipVnet == 'false' ? 'Disabled' : 'Enabled'
    sku: {
      name: openAiSkuName
    }
    deployments: [
      {
        name: chatGpt.deploymentName
        capacity: chatGpt.deploymentCapacity
        model: {
          format: 'OpenAI'
          name: chatGpt.modelName
          version: chatGpt.deploymentVersion
        }
        scaleSettings: {
          scaleType: 'Standard'
        }
      }
    ]
  }
}

// Backing storage for Azure functions backend processor
module storage 'core/storage/storage-account.bicep' = {
  name: 'storage'
  
  params: {
    name: !empty(storageAccountName) ? storageAccountName : '${abbrs.storageStorageAccounts}${resourceToken}'
    location: location
    tags: tags
    containers: [
      {name: deploymentStorageContainerName}
     ]
     networkAcls: skipVnet ? {} : {
        defaultAction: 'Deny'
      }
  }
}

var storageRoleDefinitionId  = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' // Storage Blob Data Owner role

// Allow access from api to storage account using a managed identity
module storageRoleAssignmentApi 'app/storage-Access.bicep' = {
  name: 'storageRoleAssignmentapi'
  
  params: {
    storageAccountName: storage.outputs.name
    roleDefinitionID: storageRoleDefinitionId
    principalID: apiUserAssignedIdentity.outputs.identityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

module storageRoleAssignmentUserIdentityApi 'app/storage-Access.bicep' = {
  name: 'storageRoleAssignmentUserIdentityApi'
  
  params: {
    storageAccountName: storage.outputs.name
    roleDefinitionID: storageRoleDefinitionId
    principalID: principalId
    principalType: 'User'
  }
}

var storageQueueDataContributorRoleDefinitionId  = '974c5e8b-45b9-4653-ba55-5f855dd0fb88' // Storage Queue Data Contributor

module storageQueueDataContributorRoleAssignmentprocessor 'app/storage-Access.bicep' = {
  name: 'storageQueueDataContributorRoleAssignmentprocessor'
  
  params: {
    storageAccountName: storage.outputs.name
    roleDefinitionID: storageQueueDataContributorRoleDefinitionId
    principalID: apiUserAssignedIdentity.outputs.identityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

module storageQueueDataContributorRoleAssignmentUserIdentityprocessor 'app/storage-Access.bicep' = {
  name: 'storageQueueDataContributorRoleAssignmentUserIdentityprocessor'
  
  params: {
    storageAccountName: storage.outputs.name
    roleDefinitionID: storageQueueDataContributorRoleDefinitionId
    principalID: principalId
    principalType: 'User'
  }
}

var storageTableDataContributorRoleDefinitionId  = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3' // Storage Table Data Contributor

module storageTableDataContributorRoleAssignmentprocessor 'app/storage-Access.bicep' = {
  name: 'storageTableDataContributorRoleAssignmentprocessor'
  
  params: {
    storageAccountName: storage.outputs.name
    roleDefinitionID: storageTableDataContributorRoleDefinitionId
    principalID: apiUserAssignedIdentity.outputs.identityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

module storageTableDataContributorRoleAssignmentUserIdentityprocessor 'app/storage-Access.bicep' = {
  name: 'storageTableDataContributorRoleAssignmentUserIdentityprocessor'
  
  params: {
    storageAccountName: storage.outputs.name
    roleDefinitionID: storageTableDataContributorRoleDefinitionId
    principalID: principalId
    principalType: 'User'
  }
}

var cogRoleDefinitionId  = 'a97b65f3-24c7-4388-baec-2e87135dc908' // Cognitive Services User

// Allow access from api to storage account using a managed identity
module cogRoleAssignmentApi 'app/ai-Cog-Service-Access.bicep' = {
  name: 'cogRoleAssignmentapi'
  
  params: {
    aiResourceName: ai.outputs.name
    roleDefinitionID: cogRoleDefinitionId
    principalID: apiUserAssignedIdentity.outputs.identityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

module cogRoleAssignmentUserIdentityApi 'app/ai-Cog-Service-Access.bicep' = {
  name: 'cogRoleAssignmentUserIdentityApi'
  
  params: {
    aiResourceName: ai.outputs.name
    roleDefinitionID: cogRoleDefinitionId
    principalID: principalId
    principalType: 'User'
  }
}

// Virtual Network & private endpoint to blob storage
module serviceVirtualNetwork 'app/vnet.bicep' =  if (!skipVnet) {
  name: 'serviceVirtualNetwork'
  
  params: {
    location: location
    tags: tags
    vNetName: !empty(vNetName) ? vNetName : '${abbrs.networkVirtualNetworks}${resourceToken}'
  }
}

module storagePrivateEndpoint 'app/storage-PrivateEndpoint.bicep' = if (!skipVnet) {
  name: 'servicePrivateEndpoint'
  
  params: {
    location: location
    tags: tags
    virtualNetworkName: !empty(vNetName) ? vNetName : '${abbrs.networkVirtualNetworks}${resourceToken}'
    subnetName: skipVnet ? '' : serviceVirtualNetwork.outputs.peSubnetName
    resourceName: storage.outputs.name
  }
}

// Monitor application with Azure Monitor
module monitoring './core/monitor/monitoring.bicep' = {
  name: 'monitoring'
  
  params: {
    location: location
    tags: tags
    logAnalyticsName: !empty(logAnalyticsName) ? logAnalyticsName : '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
    applicationInsightsName: !empty(applicationInsightsName) ? applicationInsightsName : '${abbrs.insightsComponents}${resourceToken}'
    disableLocalAuth: disableLocalAuth  
  }
}

var monitoringRoleDefinitionId = '3913510d-42f4-4e42-8a64-420c390055eb' // Monitoring Metrics Publisher role ID

// Allow access from api to application insights using a managed identity
module appInsightsRoleAssignmentApi './core/monitor/appinsights-access.bicep' = {
  name: 'appInsightsRoleAssignmentapi'
  
  params: {
    appInsightsName: monitoring.outputs.applicationInsightsName
    roleDefinitionID: monitoringRoleDefinitionId
    principalID: apiUserAssignedIdentity.outputs.identityPrincipalId
  }
}

// App outputs
output APPLICATIONINSIGHTS_CONNECTION_STRING string = monitoring.outputs.applicationInsightsConnectionString
output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output SERVICE_API_NAME string = api.outputs.SERVICE_API_NAME
output SERVICE_API_URI string = api.outputs.SERVICE_API_URI
output AZURE_FUNCTION_APP_NAME string = api.outputs.SERVICE_API_NAME
output AZURE_OPENAI_ENDPOINT string = ai.outputs.endpoint
