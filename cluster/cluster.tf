data "aws_availability_zones" "available" {}

data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.virginia
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

locals {
  name = var.cluster_name

  node_iam_role_name = module.eks_blueprints_addons.karpenter.node_iam_role_name

  tags = {
    Name = local.name
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.17"

  cluster_name                   = var.cluster_name
  cluster_version                = var.cluster_version
  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  create_cloudwatch_log_group   = false
  create_cluster_security_group = false
  create_node_security_group    = false

  manage_aws_auth_configmap = true
  aws_auth_roles = [
    {
      rolearn  = module.eks_blueprints_addons.karpenter.node_iam_role_arn
      username = "system:node:{{EC2PrivateDNSName}}"
      groups = [
        "system:bootstrappers",
        "system:nodes",
      ]
    },
  ]

  eks_managed_node_groups = {
    initial = {
      instance_types        = ["m5.xlarge"]
      create_security_group = false

      subnet_ids = module.vpc.private_subnets

      create_launch_template = true
      launch_template_os     = "amazonlinux2eks"

      min_size     = 1
      max_size     = 5
      desired_size = 1
    }
  }

  tags = merge(local.tags, {
    "karpenter.sh/discovery" = local.name
  })
}

#---------------------------------------------------------------
# Cluster Addons
#---------------------------------------------------------------

module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "1.12.0"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  create_delay_dependencies = [for prof in module.eks.eks_managed_node_groups : prof.node_group_arn]

  enable_aws_load_balancer_controller = true
  aws_load_balancer_controller = {
    wait = true
  }

  enable_metrics_server   = true
  enable_external_secrets = true

  enable_aws_for_fluentbit = true
  aws_for_fluentbit = {
    set = [
      {
        name  = "cloudWatchLogs.region"
        value = var.region
      }
    ]
  }

  eks_addons = {
    coredns = {
      most_recent = true

      timeouts = {
        create = "25m"
        delete = "10m"
      }
      configuration_values = jsonencode({
        resources = {
          limits = {
            cpu    = "0.25"
            memory = "256M"
          }
          requests = {
            cpu    = "0.25"
            memory = "256M"
          }
        }
      })
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      preserve    = true
      most_recent = true

      timeouts = {
        create = "25m"
        delete = "10m"
      }

      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
        enableNetworkPolicy : "true",
      })
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn
    }
  }

  enable_aws_gateway_api_controller = true
  aws_gateway_api_controller = {
    repository_username = data.aws_ecrpublic_authorization_token.token.user_name
    repository_password = data.aws_ecrpublic_authorization_token.token.password
    set = [{
      name  = "clusterVpcId"
      value = module.vpc.vpc_id
    }]
  }

  enable_karpenter                           = true
  karpenter_enable_spot_termination          = true
  karpenter_enable_instance_profile_creation = true
  karpenter = {
    repository_username = data.aws_ecrpublic_authorization_token.token.user_name
    repository_password = data.aws_ecrpublic_authorization_token.token.password

    set = [{
      name  = "replicas"
      value = "1"
    }]
  }
  karpenter_node = {
    iam_role_use_name_prefix = false
  }

  tags = local.tags
}

module "ebs_csi_driver_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.20"

  role_name_prefix = "${module.eks.cluster_name}-ebs-csi-driver-"

  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}