# Demo of Azure Key Vault, CMK for Azure Storage Service Encryption, User-Assigned Managed Identities and VNet-Endpoints
> Azure CLI scripts for setting up a simple demonstration of multiple related services used for securing data within your solutions.

The scripts in this repository were written to demonstrate three main concepts:

1. Configuration of Azure Storage Service Encryption to use a customer-managed key stored in Azure Key Vault
2. Creation of a user-assigned Managed Identity that multiple VM's can use to access Azure Key Vault, Azure Storage and a number of other services protected by Azure AD.
3. Configuration of VNet Endpoints and service specific firewalls to lock services down to specific networks.

## Installation

OS X & Linux:

These scripts were tested on Windows Subsystem for Linux with Azure CLI installed.
If you try running these on Windows you'll have issues due to dependencies on multiple Linux command line utilities.

1. [Install the Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-apt?view=azure-cli-latest) if it's not already installed.
2. Open keyvaultDemo.sh in your editor of choice and plug in your subscription ID and SSH public key information:

```py
subscriptionID="<subscription_id>"
sshPubKey="<ssh_public_key>"
```
3. Run ./keyvaultDemo.sh
4. Alternatively, run each line of the script one by one to build out the entire stack.

## What does the script do?

The script is broken into two main sections as noted above:

**PART 1 - Configuration of Azure Storage Service Encryption to use a customer-managed key stored in Azure Key Vault**

1. Create a new Key Vault
2. Create an RSA key in the Key Vault
3. Create a new Storage Account with a System-Assigned Managed Identity
4. Create a Key Vault Policy on the Key Vault to allow the Storage Account Identity Access to the RSA key
5. Enable Customer Managed Keys on the Storage account by referencing the RSA key

**PART 2 - Create two VMs that have access to a key in Key Vault via a shared user-defined managed identity. Enable VNet endpoints to secure the Key Vault to a single subnet.**

1. Create a new VNet
2. Create a Subnet within the Vnet
3. Enable VNet Endpoints for Azure Storage and Azure Key Vault on the Subnet so that we can directly access these services from within this subnet and this subnet only.
4. Create a new User-Assigned Managed Identity
5. Create two Ubuntu VMs assigning them both to the same above created User-Assigned Managed Identity. The VMs have custom data attached that configures the VMs with a simple python test app to test access to the Key Vault after provisioned.
6. Create a second Key Vault to hold application related keys. (The first vault was for the CMK only)
7. Create a new key within the second Key Vault to hold a key to be used for encryption by an application.
8. Create a Key Vault Policy on the second Key Vault to allow the VMs running under the shared User-Assigend Managed Identity to access keys within the vault.
9. Add Network rules to the firewall on the Azure Storage Account and Key Vaults to allow access only from the Subnet

## Testing Post Deployment

Poke around the various resources that have been deployed. pay close attention to the following:
* Open the VNet. Open the default subnet on the subnets blade. Notice that VNet Endpoints have been enabled for both Key Vault and Storage on this subnet. This is how we are able to reference these subnets from the firewall settings of Key Vault and Storage.
* Open the first key Vault. Take a look at the Access Policies and notice that the storage accounts Managed Identity has been granted access. This is how our Storage Account can access the master key for encrypting all data written to the account on the fly.
* Open the second Key Vault. Take a look at the Access Policies and notice that the shared User-Assigned Managed Identity has been granted access. This is how an app on our VM will be able to access Keys, Secrets, etc. within the Vault.
* Look at the Firewalls and virtual networks blade on each Key Vault and notice that the Vaults have been locked down to the Subnet that we deployed. These are not accesible from the internet.
* Open the storage account and look at the Encryption blade. Notice that this storage account is configured to use a customer managed key. You can see the reference to the key within the Vault that we created.
* Look at  Firewalls and virtual networks on the Storage Account. Notice that this account is configured to be accesible from only the Subnet that we deployed. This storage account is not accesible from the internet.
* Open one of the VMs and look at the Identity blade. You'll see that the VM has been assigned to the User-Assigned Identity that we created. Multiple VMs can be assigned to an Identity. Multiple Identities can be assigned to a VM.

Connect to one of the VM's via SSH:

```sh
ssh azadmin@<ip_address_of_vm>
```
Once in the VM, change to the directory that holds a simple test app:

```sh
cd /tmp/testapp/kv-demo/
```
Edit example.py (make sure to sudo) and plug in vault_url and key_version from the second Key Vault you deployed:
```sh
from msrestazure.azure_active_directory import MSIAuthentication
from azure.mgmt.resource import ResourceManagementClient, SubscriptionClient
from azure.keyvault import KeyVaultClient, KeyVaultAuthentication
import json
# Manage resources and resource groups - create, update and delete a resource group,
# deploy a solution into a resource group, export an ARM template. Create, read, update
# and delete a resource

vault_url="<keyvault_url>" <--------------
key_name="appkey1"
key_version="<key_version>" <--------------

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
```
Run the pl file by typing:

```sh
python example.pl
```
you should get back a JSON Web Key object from the Key Vault. This small script is using a token retrieved from the Managed Identity to call the Key Vault and retrieve the key. We didnt have to provide any credentials as  they were provided via the managed identity. Also be aware that we can only access this vault because this VM is running in a subnet that we have allowed. 

```sh
{'crv': None, 'key_ops': [u'encrypt', u'decrypt', u'sign', u'verify', u'wrapKey', u'unwrapKey'], 'e': '\x01\x00\x01', 'kty': u'RSA', 'k': None, 'n': '\xbd\xa1\xfe\xddy:\xda\xb0\xa3\x1e\xb3\xc8^T\xc4\x02\xa3\xec\xac\x0f\x14\xe6"nY.\x17(Q\x7f\xcb\x0b\xd7ZB\xb9\x02\x98[\x16\x95Zzr\x1c_\xad\x8f\xf2\xfd\xe5\xef\xbb\xe3ks\xf8\xfd\x95|\x1a\xd9\xc5\x8f\xd1\xed\xd9t]L\xe2-\x93\xba\xab\xfa\xe1TC\xad~c+\x8b\xbc\x7fg\x00\x9d}K\xac}j{\xf0L\xa7\xf1S \xf6\xee\xf0\xcf\x8b\xe0\x11\xaf\xe0.\x87\xdfQr\xdb"\xefx\x15F\xf9\xcc\x06\\\x83\xc7X\x99\xe9\xbf\x8e\xe7\xd5\x19M\x92.|x\xa0I@X\xf3m\x7f\xa7\xb4\x8e\x81U\xc1+\\\xe3\xa6\xe1\xbe \x0e\n]\xf7+\xb1\xad:\xfdA\xd9\xcb.\x87\t\xeb\x94\xef\x06=\x04\r\x05\x81\x9f\xadx5u\xc8\xdf\x1f\x12o\x19\xf8\x10*!\x16\xe1\xc7\xc7M\x0b\xfb\n\xb1v\xd1+\x95[>q\x04\xcb"\xb0\xfdG46\xaaQ(\x9f\\\xed\xe8\xfc]g2\x86Wx\xf8\xd9\x1a\xca\xe02\xec\xa1^\xd1u\xaed\xcc\x05u\xca\x8b\x19', 'q': None, 'p': None, 'additional_properties': {}, 't': None, 'kid': u'https://rlheulkvdemo-keyvault2.vault.azure.net/keys/appkey1/66f96e4342eb413f9c8ad08bd2190ae1', 'qi': None, 'x': None, 'dq': None, 'y': None, 'dp': None, 'd': None}
```
