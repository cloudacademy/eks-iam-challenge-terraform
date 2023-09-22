### Provider
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.10.0"
    }
  }
}

locals {
  region = "us-west-2"
}

provider "aws" {
  region = local.region
}

data "aws_availability_zones" "available" {}

data "aws_caller_identity" "current" {}

locals {
  name        = "cloudacademydevops"
  environment = "prod"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 2)

  k8s = {
    cluster_name   = "${local.name}-eks-${local.environment}"
    version        = "1.27"
    instance_types = ["t3.small"]
    capacity_type  = "ON_DEMAND"
    disk_size      = 10
    min_size       = 2
    max_size       = 2
    desired_size   = 2
  }
}

#====================================

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = ">= 5.0.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 52)]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  manage_default_network_acl    = true
  manage_default_route_table    = true
  manage_default_security_group = true

  default_network_acl_tags = {
    Name = "${local.name}-default"
  }

  default_route_table_tags = {
    Name = "${local.name}-default"
  }

  default_security_group_tags = {
    Name = "${local.name}-default"
  }

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = {
    Name        = "${local.name}-eks"
    Environment = local.environment
  }
}

module "eks" {
  # forked from terraform-aws-modules/eks/aws, fixes deprecated resolve_conflicts issue
  source = "github.com/cloudacademy/terraform-aws-eks"

  cluster_name    = local.k8s.cluster_name
  cluster_version = local.k8s.version

  cluster_endpoint_public_access   = true
  attach_cluster_encryption_policy = false
  create_iam_role                  = true

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
  }

  aws_auth_roles = [

  ]

  aws_auth_users = [
    {
      userarn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/eks-admin-user"
      username = "eks-admin-user"
      groups   = ["system:masters"]
    }

  ]

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    default = {
      use_custom_launch_template = false
      create_iam_role            = true 

      instance_types = local.k8s.instance_types
      capacity_type  = local.k8s.capacity_type

      disk_size = local.k8s.disk_size

      min_size     = local.k8s.min_size
      max_size     = local.k8s.max_size
      desired_size = local.k8s.desired_size

      credit_specification = {
        cpu_credits = "standard"
      }
    }
  }

  //don't do in production - this is for demo/lab purposes only
  create_kms_key            = false
  cluster_encryption_config = {}

  tags = {
    Name        = "${local.name}-eks"
    Environment = local.environment
  }
}
