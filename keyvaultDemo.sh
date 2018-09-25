#!/bin/bash

## AUTHOR: Ken Skvarcius 9.2018
## DESCRIPTION: This script is simple demonstration of how to set up Azure Storage
## using customer-managed keys in Azure Key Vault. Behind the scenes this takes
## advantage of Managed Service Identity (MSI). We also demonstrate how to set up MSI
## for a VM such that two VMs can access keys stored in Key Vault without managing credentials.
## 
## The script is laid out in two parts:
## -----------------------------------------------
## PART 1 - Enable CMK on a Storage Account using a key stored in a dedicated Key Vault
## -----------------------------------------------
## PART 2 - Create two VMs that have access to a key in Key Vault via a user-defined managed identity. Enable VNet endpoints to secure the Key Vault to a single subnet.
## -----------------------------------------------
## Echo on for visibility
set -o xtrace
## -----------------------------------------------

# Before running plug in your subscription ID and public SSH key.
subscriptionID="<subscription_id>"
resourceGroupName="KeyVaultDemo-Rg"
location="eastus2"
baseResourceName="kvdemo"
# Random string for naming to avoid name collisions
rand=$(cat /dev/urandom | tr -dc 'a-z' | fold -w 6 | head -n 1)
vmUserName="azadmin"
sshPubKey="<ssh_public_key>"

# List available subscriptions
az account list -o table

# Set the subscription that you want to deploy resources into
az account set -s $subscriptionID

# Create a resource group
az group create --name $resourceGroupName --location $location

## -----------------------------------------------
## PART 1 - Enables CMK on a Storage Account

# Create a Key Vault w/ soft delete and purge protection enabled (both required for CMK)
# These two options prevent the accidental destruction of the vault and key material both of which would make data encrypted using a CMK unreadable.
# Key backups are recommended.
az keyvault create --name "$rand$baseResourceName-keyvault" --enable-soft-delete true --enable-purge-protection true --location $location --resource-group $resourceGroupName

# Create a key in the new vault. This key will be used as a master key to encrypt downstream account and data keys used for data encryption in the storage account.
az keyvault key create --name "cmk1" --vault-name "$rand$baseResourceName-keyvault" --kty RSA 

# Retrieve the current version of the newly created key. We'll need it when we turn CMK on on the storage account.
encryptionKeyKID=$(az keyvault key show --vault-name "$rand$baseResourceName-keyvault" --name "cmk1" --query key.kid)
# Pull the vestion from the KID and trim off the trailing quote.
encryptionKeyVersion=${encryptionKeyKID##*/}
encryptionKeyVersion=${encryptionKeyVersion%\"}

# Create a storage account. make sure to create a system-assigned managed service identity (MSI) as part of the account creation process. This will be used to grant access to the key in keyvault.
# Set the default firewall setting to deny
az storage account create --name "$rand$baseResourceName" --resource-group $resourceGroupName --location $location --assign-identity

# Grab the storage account identity. We'll need it to create a Key Vault policy so the account can access the CMK.
storageAccountSPNIdentity=$(az storage account show --name "$rand$baseResourceName" --resource-group $resourceGroupName --query identity.principalId)
# Strip quotes
storageAccountSPNIdentity=$(echo $storageAccountSPNIdentity | sed "s/^\([\"']\)\(.*\)\1\$/\2/g")

# Create a key policy granting the storage account MSI access to the CMK
az keyvault set-policy --name "$rand$baseResourceName-keyvault" --key-permissions get wrapkey unwrapkey --object-id $storageAccountSPNIdentity

# Sleep and allow time for policy to fully deploy.
sleep 15

# Enable CMK on the storage account
az storage account update --name "$rand$baseResourceName" --resource-group $resourceGroupName --encryption-key-vault "https://$rand$baseResourceName-keyvault.vault.azure.net/" --encryption-key-source Microsoft.Keyvault --encryption-key-name "cmk1" --encryption-key-version $encryptionKeyVersion


## -----------------------------------------------
## Part 2 - Create two VMs that have access to a KeyVault Key via a user-defined managed identity.
## Enable VNet endpoints to secure the Key Vault

# Create a VNet
az network vnet create --name "$rand$baseResourceName-vnet" --resource-group $resourceGroupName --location $location

# Create a subnet within the VNet
az network vnet subnet create --resource-group $resourceGroupName --vnet-name "$rand$baseResourceName-vnet" --name "default" --address-prefix 10.0.0.0/24

# What service endpoints are available?
az network vnet list-endpoint-services --location $location

# Update the default subnet to enable the VNet endpoints for Key Vault and Storage. This will allow us to lock Key Vaults and Storage Accounts down to this subnet only.
az network vnet subnet update --resource-group $resourceGroupName --vnet-name "$rand$baseResourceName-vnet" --name "default" --service-endpoints "Microsoft.KeyVault" "Microsoft.Storage"

# Add a network ACL to the CMK vault firewall to allow access only from the above created subnet and MS services
az keyvault network-rule add --name "$rand$baseResourceName-keyvault" --resource-group $resourceGroupName --subnet "default" --vnet-name "$rand$baseResourceName-vnet"

# Add a network ACL to the Azure Storage Account firewall to allow access only from the above created subnet and MS services
az storage account network-rule add --account-name "$rand$baseResourceName" --resource-group $resourceGroupName --subnet "default" --vnet-name "$rand$baseResourceName-vnet"

# Set a default deny on the Key Vault firewall.
az keyvault update --resource-group $resourceGroupName --name "$rand$baseResourceName-keyvault" --default-action Deny

# Set a default deny on the Storage Account
az storage account update --resource-group $resourceGroupName --name "$rand$baseResourceName" --default-action Deny --encryption-key-vault "https://$rand$baseResourceName-keyvault.vault.azure.net/" --encryption-key-source Microsoft.Keyvault --encryption-key-name "cmk1" --encryption-key-version $encryptionKeyVersion

# Create a new user-assigned managed identity (uami). This is a standalone ARM resource and can be leveraged across multiple machines.
az identity create --resource-group $resourceGroupName --name "$rand$baseResourceName-uami"

# Get the uami id so that we can reference it when creating a new VM.
uamiID=$(az identity show --name "$rand$baseResourceName-uami" --resource-group $resourceGroupName --query id)
uamiID=$(echo $uamiID | sed "s/^\([\"']\)\(.*\)\1\$/\2/g")

# Get the uami's principal ID so that we can create a new keyvault policy to grant it access to the vault.
uamiPrincipal=$(az identity show --name "$rand$baseResourceName-uami" --resource-group $resourceGroupName --query principalId)
# Strip quotes
uamiPrincipal=$(echo $uamiPrincipal | sed "s/^\([\"']\)\(.*\)\1\$/\2/g")

# Launch a VM into the subnet so that we can test storage and vault access. Assign a managed service identity for the machine.
az vm create --name "$rand$baseResourceName-vm" --resource-group $resourceGroupName --image UbuntuLTS --vnet-name "$rand$baseResourceName-vnet" --subnet "default" --ssh-key-value "$sshPubKey" --admin-username "$vmUserName" --custom-data customdata.sh --assign-identity $uamiID

# Launch a second VM into the subnet. This VM will run under the same user-assigned managed identity.
az vm create --name "$rand$baseResourceName-vm2" --resource-group $resourceGroupName --image UbuntuLTS --vnet-name "$rand$baseResourceName-vnet" --subnet "default" --ssh-key-value "$sshPubKey" --admin-username "$vmUserName" --custom-data customdata.sh --assign-identity $uamiID

# Create a second new Key Vault to hold a key for encrypting data from an app on the VM
az keyvault create --name "$rand$baseResourceName-keyvault2" --location $location --resource-group $resourceGroupName

# Create a key in the vault. This key will be used to encrypt/decrypt data from code running on the VM
az keyvault key create --name "appkey1" --vault-name "$rand$baseResourceName-keyvault2" --kty RSA 

# Add a network ACL to the vault to allow access only from the above created subnet
az keyvault network-rule add --name "$rand$baseResourceName-keyvault2" --resource-group $resourceGroupName --subnet "default" --vnet-name "$rand$baseResourceName-vnet"

# Enable the rule above by setting a default deny
az keyvault update --resource-group $resourceGroupName --name "$rand$baseResourceName-keyvault2" --default-action Deny

# Create a key policy granting the VM identity access to the Vault.. This will allow us to encrypt / decrypt data using a key in the vault.
az keyvault set-policy --name "$rand$baseResourceName-keyvault2" --key-permissions get encrypt decrypt --object-id $uamiPrincipal