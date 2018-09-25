from msrestazure.azure_active_directory import MSIAuthentication
from azure.mgmt.resource import ResourceManagementClient, SubscriptionClient
from azure.keyvault import KeyVaultClient, KeyVaultAuthentication
import json
# Manage resources and resource groups - create, update and delete a resource group,
# deploy a solution into a resource group, export an ARM template. Create, read, update
# and delete a resource

vault_url="<keyvault_url>"
key_name="appkey1"
key_version="<key_version>"

def run_example():
    """MSI Authentication example."""

    #
    # Create System Assigned MSI Authentication
    #
    credentials = MSIAuthentication()

    client = KeyVaultClient(credentials)
    
    key_bundle = client.get_key(vault_url, key_name, key_version)
    json_key = key_bundle.key
    print json_key

if __name__ == "__main__":
    run_example()
