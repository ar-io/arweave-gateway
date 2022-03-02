# arweave-gateway

The classic Arweave Gateway, deployable in AWS Cloud using Terraform

This solution is provided *as-is* with limited support.

Have a question?  Join the AR.IO Discord and let us know!

https://discord.gg/6DHvefQNDx

## Getting started

Before starting with aws, make sure to have IAM user/role with which you can use to deploy the gateway resources.
Use best practices in how you organize your organzational units, fitting to your needs.

We deploy terraform using *terragrunt* but that is optional, we'll nontheless describe this process using terragrunt.

```console
# create a deployment target under environments
# here we create the production target
mkdir -p terraform/environments/prod
```

Next create a new terraform file `terraform/environments/prod/main.tf`

```tf
terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 3.64.0"
    }
  }
  backend "s3" {
    bucket         = "terraform-deployment-bucket" # <- CHANGEME
    key            = "terraform"
    region         = "us-east-1" # <- CHANGEME IF NEEDED
    dynamodb_table = "terraform-lock"
    role_arn       = "arn:aws:iam::000000000000:role/DeploymentRole" # <- CHANGEME
  }
}

resource "aws_s3_bucket" "bucket" {
  bucket = "terraform-deployment-bucket" # <- CHANGEME
}

resource "aws_dynamodb_table" "terraform_state_lock" {
  name           = "terraform-lock"
  read_capacity  = 5
  write_capacity = 5
  hash_key       = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
}


provider "aws" {
  region = "us-east-1" # <- CHANGEME IF NEEDED

  assume_role {
    role_arn = "arn:aws:iam::000000000000:role/DeploymentRole"
  }
}
```

Next create a new terraform variables file in hcl format `terraform/environments/prod/terragrunt.hcl`


```hcl
include {
  path = find_in_parent_folders()
}

terraform {
  source = "../../src"
}

inputs = {

  domain_name = "domain.com" # <- CHANGEME

  environment = "prod" # <- CHANGEME IF NEEDED

  cidr = "10.80.0.0/16" # <- CHANGEME IF NEEDED

  region = "us-east-1" # <- CHANGEME IF NEEDED

  azs = ["us-east-1a", "us-east-1b"] # <- CHANGEME IF NEEDED

  private_subnets = ["10.80.1.0/24", "10.80.3.0/24"] # <- CHANGEME IF NEEDED

  public_subnets = ["10.80.0.0/24", "10.80.2.0/24"] # <- CHANGEME IF NEEDED

  default_kms_id = "00000000-0000-0000-0000-000000000000" # <- CHANGEME

  # IAM
  account_id      = "000000000000" # <- CHANGEME
  deployment_role = "arn:aws:iam::000000000000:role/DeploymentRole" # <- CHANGEME

  # Resouces
  rds_instance_type          = "db.r5.large" # <- CHANGEME IF NEEDED
  ami_ubuntu_latest          = "ami-09eaf2d6779f94558" # https://cloud-images.ubuntu.com/locator/ec2/
  ec2_import_blocks_resource = "t2.micro" # <- CHANGEME IF NEEDED
  import_blocks_ami          = "ami-0000000000000000" # <- CHANGEME AFTER DEPLOYING AMI
}
```

Next cd into `terraform/environments/prod` and call the following

```console
# bootstraping terragrunt can be tedious
# that's because many resources are expected to exist
# prior to deploying specific resources
# we recommend creating deployment s3 bucket and
# dynamodb lock before proceeding

$ terragrunt init

# after success, keep applying more resources with

$ terragrunt plan

$ terragrunt apply
```

*WARNING* the terraform code will need to be modified to your infrastructure needs.
You'll also most defenitely need to comment out (or set count = 0) to parts which
need manual bootstraping.


## Continuous Integration

# ec2

The import-blocks code is deployed to an ec2.
The the code is deployed using nix package manager, but
this can be changed to more traditional tools like yarn.
If you wish to go further with nix, please refer to

https://github.com/cachix/install-nix-action

where you can build nix code from github actions.

We use the following bash snippet in our github actions
to push a newly built AMI image to aws.
Feel free to use this ad verbatum, or use it as skeleton
for deploying in your CI deployment service.

```bash
task_id=$(aws ec2 import-snapshot --description "Arweaeve Gateway import-blocks AMI Import" --disk-container \
        "{ \"Description\":\"v$GITHUB_RUN_NUMBER\", \
           \"UserBucket\":{ \"S3Bucket\":\"CHANGEME-MYS3BUCKET-amis\", \
           \"S3Key\":\"import-blocks-x86_64-linux.vhd\" } }" | jq -r '.ImportTaskId' )

while [[ $(aws ec2 describe-import-snapshot-tasks --import-task-ids $task_id | \
         jq -r '.ImportSnapshotTasks[0].SnapshotTaskDetail.Status') =~ ^(pending|active)$ ]]
do
   sleep 3
done
snapshot_id=$(aws ec2 describe-import-snapshot-tasks --import-task-ids $task_id | jq -r '.ImportSnapshotTasks[0].SnapshotTaskDetail.SnapshotId')
echo SNAPSHOTID $snapshot_id
aws ec2 describe-import-snapshot-tasks
aws ec2 wait snapshot-completed --snapshot-ids $snapshot_id
aws ec2 register-image --name "import-blocks-$GITHUB_RUN_NUMBER" --description "v$GITHUB_RUN_NUMBER" \
  --architecture x86_64 --root-device-name "/dev/xvda" --virtualization-type hvm \
  --block-device-mappings "[ \
   { \
     \"DeviceName\": \"/dev/xvda\", \
     \"Ebs\": {\"SnapshotId\":\"$snapshot_id\",\"VolumeSize\":100,\"DeleteOnTermination\":true,\"VolumeType\":\"gp3\", \"Iops\":300} \
   } \
]"
```
