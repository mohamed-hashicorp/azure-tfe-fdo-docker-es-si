terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.57.0"
    }

    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    acme = {
      source  = "vancluever/acme"
      version = "~> 2.0"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }

  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  subscription_id = var.subscription_id
}

provider "aws" {
  region = var.aws_region
}

provider "acme" {
  server_url = var.acme_server_url
}

resource "azurerm_resource_group" "rg" {
  name     = "${var.prefix}-rg"
  location = var.location
}


resource "azurerm_virtual_network" "vnet" {
  name                = "${var.prefix}-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.10.0.0/16"]
}

resource "azurerm_subnet" "subnet" {
  name                 = "${var.prefix}-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.10.1.0/24"]
}

resource "azurerm_public_ip" "pip" {
  name                = "${var.prefix}-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_security_group" "nsg" {
  name                = "${var.prefix}-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "HTTPS"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

}

resource "azurerm_network_interface" "nic" {
  name                = "${var.prefix}-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pip.id
  }

  depends_on = [
    azurerm_subnet.subnet
  ]

}

resource "azurerm_network_interface_security_group_association" "nic_nsg" {
  network_interface_id      = azurerm_network_interface.nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_linux_virtual_machine" "vm" {
  name                = "${var.prefix}-vm"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  size                = "Standard_D2s_v3"

  admin_username                  = var.admin_username
  disable_password_authentication = true

  user_data = base64encode(templatefile("${path.module}/cloud-init.tftpl", {
    admin_user              = var.admin_username
    server_cert             = indent(6, acme_certificate.server.certificate_pem)
    private_key             = indent(6, acme_certificate.server.private_key_pem)
    bundle_certs            = indent(6, acme_certificate.server.issuer_pem)
    email                   = var.email
    tfe_license             = var.tfe_license
    tfe_hostname            = var.dns_record
    tfe_admin_password      = var.tfe_admin_password
    tfe_encryption_password = var.tfe_encryption_password
    tfe_image_tag           = var.tfe_image_tag
    certs_dir               = var.certs_dir
    data_dir                = var.data_dir

    tfe_db_user     = azurerm_postgresql_flexible_server.tfe_db.administrator_login
    tfe_db_password = var.tfe_database_password
    tfe_db_host     = azurerm_postgresql_flexible_server.tfe_db.fqdn
    tfe_db_name     = var.tfe_db_name

    tfe_azure_account_name = azurerm_storage_account.tfe_storage.name
    tfe_azure_container    = azurerm_storage_container.tfe_container.name
    tfe_azure_account_key  = azurerm_storage_account.tfe_storage.primary_access_key

    tfe_azure_account_name = azurerm_storage_account.tfe_storage.name
    tfe_azure_container    = azurerm_storage_container.tfe_container.name
    tfe_azure_account_key  = azurerm_storage_account.tfe_storage.primary_access_key

  }))

  network_interface_ids = [azurerm_network_interface.nic.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}

# Separate managed data disk (this is the one you will resize)
resource "azurerm_managed_disk" "data" {
  name                 = "${var.prefix}-data1"
  location             = azurerm_resource_group.rg.location
  resource_group_name  = azurerm_resource_group.rg.name
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_size_gb
}

resource "azurerm_virtual_machine_data_disk_attachment" "data_attach" {
  managed_disk_id    = azurerm_managed_disk.data.id
  virtual_machine_id = azurerm_linux_virtual_machine.vm.id
  lun                = 0
  caching            = "ReadOnly"
  # avoid getting error VM is not found 
  depends_on = [azurerm_linux_virtual_machine.vm]
}

output "public_ip" {
  value = azurerm_public_ip.pip.ip_address
}

# --- Route53 Hosted Zone ---
data "aws_route53_zone" "server_zone" {
  name         = var.hosted_zone_name
  private_zone = false
}

# --- Route53 A Record pointing to EC2 public IP ---
resource "aws_route53_record" "server" {
  zone_id = data.aws_route53_zone.server_zone.zone_id
  name    = var.dns_record
  type    = "A"
  ttl     = 60

  records = [azurerm_public_ip.pip.ip_address]
}

# ACME account private key (used to register with Let's Encrypt)
resource "tls_private_key" "acme_account" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# ACME registration (your Let's Encrypt account)
resource "acme_registration" "this" {
  account_key_pem = tls_private_key.acme_account.private_key_pem
  email_address   = var.email
}

# ACME certificate for your FQDN
resource "acme_certificate" "server" {
  account_key_pem = acme_registration.this.account_key_pem
  common_name     = var.dns_record

  # Default is 30 days – cert will only be renewed when it's close to expiring,
  # not on every apply. :contentReference[oaicite:1]{index=1}
  min_days_remaining = 30

  dns_challenge {
    provider = "route53"
    config = {
      AWS_HOSTED_ZONE_ID = data.aws_route53_zone.server_zone.zone_id
      AWS_REGION         = var.aws_region
    }
  }
}

# Database resource
resource "azurerm_postgresql_flexible_server" "tfe_db" {
  name                          = "${var.prefix}-tfe-db"
  resource_group_name           = azurerm_resource_group.rg.name
  location                      = azurerm_resource_group.rg.location
  version                       = "16" # Supported version for TFE
  administrator_login           = "tfeadmin"
  administrator_password        = var.tfe_database_password
  storage_mb                    = 32768
  sku_name                      = "GP_Standard_D2s_v3"
  public_network_access_enabled = true # Ensure your VM can reach it
}

# Required to allow the TFE VM to connect to the DB
resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_vm" {
  name             = "allow-tfe-vm"
  server_id        = azurerm_postgresql_flexible_server.tfe_db.id
  start_ip_address = azurerm_public_ip.pip.ip_address
  end_ip_address   = azurerm_public_ip.pip.ip_address
}

resource "azurerm_postgresql_flexible_server_database" "tfe_db_name" {
  name      = var.tfe_db_name
  server_id = azurerm_postgresql_flexible_server.tfe_db.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# Fix for "Failed to Initialize Plugins" as per HashiCorp Support
resource "azurerm_postgresql_flexible_server_configuration" "require_ssl" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.tfe_db.id
  value     = "off" # TFE often requires managing its own SSL or specific param handling
}

# Fix for "Failed to Initialize Plugins": Enable required extensions
resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.tfe_db.id
  value     = "CITEXT,HSTORE,UUID-OSSP"
}

# Blob storage
resource "azurerm_storage_account" "tfe_storage" {
  name                     = "${lower(replace(var.prefix, "-", ""))}tfestore"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "tfe_container" {
  name                  = var.blob_container_name
  storage_account_name  = azurerm_storage_account.tfe_storage.name
  container_access_type = "private"
}