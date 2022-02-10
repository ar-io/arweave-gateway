variable "environment" {
  type        = string
  description = "deployment environment (ex. test, dev, prod)"
}

variable "domain_name" {
  type        = string
  description = "Domain name for a given target"
}

variable "region" {
  type        = string
  description = "aws-region"
}

variable "cidr" {
  type        = string
  description = "CIDR block for the VPC"
}

variable "azs" {
  type        = list
  description = "List of availability zones"
}

variable "public_subnets" {
  type        = list
  description = "List of public subnet CIDR blocks"
}

variable "private_subnets" {
  type        = list
  description = "List of public subnet CIDR blocks"
}

variable "account_id" {
  description = "The account-id of given environment"
  type        = string
}

variable "deployment_role" {
  description = "The role which handles deployments"
  type        = string
}

variable "arweave_account" {
  description = "The arn of the old arweave's gateway aws account"
  type        = string
}

variable "default_kms_id" {
  description = "The default created kms key called default"
  type        = string
}

# resources

variable "rds_instance_type" {
  description = "The resource type for rds+postgres ex: db.t4g.2xlarge"
  type = string
}

variable "ami_ubuntu_latest" {
  description = "Region specific AMI image identifier for latest ubuntu image"
  type = string
}


variable "ec2_import_blocks_resource" {
  description = "The resource type for the ec2 instance responsible for importing blocks"
  type = string
}

variable import_blocks_ami {
  description = "The AMI id of the privately deployed ami image"
  type = string
}
