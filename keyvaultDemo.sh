#!/bin/bash

## DESCRIPTION: Simple demonstration of Azure Key Vualt and CMK for Azure Storage 
## This script:

## PART 1 - Enables CMK on a Storage Account
## 1.) Creates a resource group
## 2.) Creates a KeyVault to hold a CMK for an Azure Storage Accout
## 3.) Creates a key in the KeyVaule
## 4.) Creates a Storage Account with MSI
## 5.) Creates a KeyVault Policy for the above Vault allowing the MSI from the storage account access
## 6.) Enables CMK on the Storage account

## Part 2 - Creates a VM that has access to a KeyVault Key
## 7.) Creates a VNet and a Subnet
## 8.) Enables the VNet Endpoint for KeyVault on the subnet
## 9.) Sets the firewall up on the KeyVault so that only the subnet can access it.


# echo on
set -o xtrace

# base variables
subscriptionID="<subscription_id>"
resourceGroupName="KeyVaultDemo-Rg"
location="eastus2"
baseResourceName="kvdemo"
rand=$(cat /dev/urandom | tr -dc 'a-z' | fold -w 6 | head -n 1)
vmUserName="azadmin"
sshPubKey="<ssh_key>"

# List available subscriptions
az account list -o table

# Set the subscription that you want to work with
az account set -s $subscriptionID

# Create a resource group
az group create --name $resourceGroupName --location $location

# Create a Key Vault w/ soft delete and purge protection enabled (both required for CMK)
# These two options prevent the accidental destruction of the vault and key material given the relationship to an Azure Storage account
az keyvault create --name "$rand$baseResourceName-keyvault" --enable-soft-delete true --enable-purge-protection true --location $location --resource-group $resourceGroupName

# Create a key in the vault. This key will be used as a master key to encrypt downstream keys used for data encryption in the storage account.
az keyvault key create --name "cmk1" --vault-name "$rand$baseResourceName-keyvault" --kty RSA 

# Grab the new keys version
encryptionKeyKID=$(az keyvault key show --vault-name "$rand$baseResourceName-keyvault" --name "cmk1" --query key.kid)
# pull the version from KID and strip the trailing quote
encryptionKeyVersion=${encryptionKeyKID##*/}
encryptionKeyVersion=${encryptionKeyVersion%\"}

# Create a storage account. make sure to create a managed service identity when creating the account. This will be used to grant access to the key in keyvault.
az storage account create --name "$rand$baseResourceName" --resource-group $resourceGroupName --location $location --assign-identity

# Grab the storage account identity
storageAccountSPNIdentity=$(az storage account show --name "$rand$baseResourceName" --resource-group $resourceGroupName --query identity.principalId)
# Strip quotes
storageAccountSPNIdentity=$(echo $storageAccountSPNIdentity | sed "s/^\([\"']\)\(.*\)\1\$/\2/g")

# Create a key policy granting the storage account SPN access to the CMK
az keyvault set-policy --name "$rand$baseResourceName-keyvault" --key-permissions get wrapkey unwrapkey --object-id $storageAccountSPNIdentity

# Sleep and allow time for policy to fully deploy.
sleep 15

# Enable CMK on the storage account
az storage account update --name "$rand$baseResourceName" --resource-group $resourceGroupName --encryption-key-vault "https://$rand$baseResourceName-keyvault.vault.azure.net/" --encryption-key-source Microsoft.Keyvault --encryption-key-name "cmk1" --encryption-key-version $encryptionKeyVersion

# Create a VNet
az network vnet create --name "$rand$baseResourceName-vnet" --resource-group $resourceGroupName --location $location

# Create a subnet within the VNet
az network vnet subnet create --resource-group $resourceGroupName --vnet-name "$rand$baseResourceName-vnet" --name "default" --address-prefix 10.0.0.0/24

# What service endpoints are available?
az network vnet list-endpoint-services --location $location

# Update the default subnet to enable VNet endpoint for Key Vault
az network vnet subnet update --resource-group $resourceGroupName --vnet-name "$rand$baseResourceName-vnet" --name "default" --service-endpoints "Microsoft.KeyVault"

# Add a network ACL to the vault to allow access only from the above created subnet
az keyvault network-rule add --name "$rand$baseResourceName-keyvault" --resource-group $resourceGroupName --subnet "default" --vnet-name "$rand$baseResourceName-vnet"

# Enable the rule above by setting a default deny
az keyvault update --resource-group $resourceGroupName --name "$rand$baseResourceName-keyvault" --default-action Deny

# Launch a VM into the subnet so that we can test storage and vault access. Assign a managed service identity for the machine.
az vm create --name "$rand$baseResourceName-vm" --resource-group $resourceGroupName --image UbuntuLTS --vnet-name "$rand$baseResourceName-vnet" --subnet "default" --ssh-key-value "$sshPubKey" --admin-username "$vmUserName" --custom-data customdata.sh --assign-identity

# Create a second new Key Vault to hold a key for encrypting data from an app on the VM
az keyvault create --name "$rand$baseResourceName-keyvault2" --location $location --resource-group $resourceGroupName

# Create a key in the vault. This key will be used to encrypt/decrypt data from code running on the VM
az keyvault key create --name "appkey1" --vault-name "$rand$baseResourceName-keyvault2" --kty RSA 

# Add a network ACL to the vault to allow access only from the above created subnet
az keyvault network-rule add --name "$rand$baseResourceName-keyvault2" --resource-group $resourceGroupName --subnet "default" --vnet-name "$rand$baseResourceName-vnet"

# Enable the rule above by setting a default deny
az keyvault update --resource-group $resourceGroupName --name "$rand$baseResourceName-keyvault2" --default-action Deny

# Get the VM's identity so that we can create a new keyvault policy to grant it access to the vault.
vmSPNIdentity=$(az vm show --name "$rand$baseResourceName-vm" --resource-group $resourceGroupName --query identity.principalId)
# Strip quotes
vmSPNIdentity=$(echo $vmSPNIdentity | sed "s/^\([\"']\)\(.*\)\1\$/\2/g")

# Create a key policy granting the VM identity access to the Vault.. This will allow us to encrypt / decrypt data using a key in the vault.
az keyvault set-policy --name "$rand$baseResourceName-keyvault2" --key-permissions get encrypt decrypt --object-id $vmSPNIdentity