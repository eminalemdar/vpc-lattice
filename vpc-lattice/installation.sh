#!/bin/bash
: '
The following script has one function: 
Install function declares the required environment
variables and installs the required Helm Chart for the
AWS Gateway API Controller.
'

declare AWS_REGION="eu-west-1"
declare CLUSTER_NAME="eks-cluster"

install(){
    # Configure Authentication for the Kubernetes Cluster
    aws eks --region $AWS_REGION update-kubeconfig --name $CLUSTER_NAME

    echo "===================================================="
    echo "Configuring authentication with Public ECR"
    echo "===================================================="

    aws ecr-public get-login-password --region us-east-1 | helm registry login --username AWS --password-stdin public.ecr.aws

    echo "===================================================="
    echo "Creating IRSA for EKS Cluster"
    echo "===================================================="

    ###########################################################
    # You can skip this step if you have already configured   #
    # IRSA for your Kubernetes Cluster.                       #
    ###########################################################
  
    eksctl utils associate-iam-oidc-provider --cluster ${CLUSTER_NAME} --region ${AWS_REGION} --approve

    echo "===================================================="
    echo "Installing AWS Gateway API Controller"
    echo "===================================================="

    CLUSTER_SG=$(aws eks describe-cluster --name ${CLUSTER_NAME} --output json| jq -r '.cluster.resourcesVpcConfig.clusterSecurityGroupId')
    PREFIX_LIST_ID=$(aws ec2 describe-managed-prefix-lists --query "PrefixLists[?PrefixListName=="\'com.amazonaws.${AWS_REGION}.vpc-lattice\'"].PrefixListId" | jq -r '.[]')
    aws ec2 authorize-security-group-ingress --group-id ${CLUSTER_SG} --ip-permissions "PrefixListIds=[{PrefixListId=${PREFIX_LIST_ID}}],IpProtocol=-1"

    IAM_ROLE="eks-cluster-lattice"
    IAM_ROLE_ARN=$(aws iam get-role --role-name=${IAM_ROLE} --query Role.Arn --output text)
    NAMESPACE="gateway-api-controller"
    CHART_VERSION="1.0.0"

    helm install gateway-api-controller \
        oci://public.ecr.aws/aws-application-networking-k8s/aws-gateway-controller-chart \
        --version=v${CHART_VERSION} \
        --create-namespace \
        --set=aws.region=${AWS_REGION} \
        --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${IAM_ROLE_ARN}" \
        --set=defaultServiceNetwork=${CLUSTER_NAME} \
        --namespace ${NAMESPACE} \
        --wait
}

install