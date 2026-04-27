terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # EKS module v20.37 caps at AWS v5 (< 6.0.0). The main course's terraform/
      # uses v6 — these two configs are independent.
      version = "~> 5.95"
    }
  }
}

provider "aws" {
  region = var.region
}

# ----------------------------------------------------------------------
# VPC — public-only, no NAT Gateway (cost shortcut for demo).
# Trade-off documented in GITOPS-DEMO.md §10. Nodes get public IPs so
# they can pull container images from Docker Hub directly.
# ----------------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.21"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs            = ["${var.region}a", "${var.region}b"]
  public_subnets = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway      = false
  map_public_ip_on_launch = true
  enable_dns_hostnames    = true
  enable_dns_support      = true

  # EKS uses these tags to discover subnets for ELB provisioning (if you ever add an ALB).
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  tags = {
    Project = "skillpulse"
  }
}

# ----------------------------------------------------------------------
# EKS cluster + a single managed node group on a t3.large node.
# kube-prometheus-stack is memory-heavy; t3.medium was too tight.
# ----------------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.37"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  cluster_endpoint_public_access = true

  # Grants the IAM identity that runs `terraform apply` cluster-admin via the
  # EKS access entries API — so kubectl works immediately after `update-kubeconfig`.
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      desired_size   = 1
      min_size       = 1
      max_size       = 2
      instance_types = [var.node_instance_type]

      subnet_ids = module.vpc.public_subnets
    }
  }

  tags = {
    Project = "skillpulse"
  }
}
