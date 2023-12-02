# Application Service Discovery with VPC Lattice on Amazon EKS

This repository contains examples for **VPC Lattice** implementation on **Amazon EKS**.

<p align="center">
    <img src="images/kubernetes.png" alt="Kubernetes logo" width="150" />
    <img src="images/lattice.png" alt="VPC Lattice logo" width="150" />
    <img src="images/eks.png" alt="Amazon EKS logo" width="150" />
</p>

[Amazon VPC Lattice](https://aws.amazon.com/vpc/lattice/) is an application layer networking service that gives you a consistent way to connect, secure, and monitor service-to-service communication without any prior networking expertise. 

The resources in this repository deploys **The AWS Gateway API Controller** and this controller is an implementation of the [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/). The controller then integrates VPC Lattice with the Kubernetes Gateway API. The controller watches for the creation of Gateway API resources such as gateways and routes and provisions corresponding Amazon VPC Lattice objects. This enables users to configure VPC Lattice Service Networks using Kubernetes APIs, without needing to write custom code or manage sidecar proxies.

![lattice-diagram](<./images/lattice-diagram.png>)

## Prerequisites

- A Kubernetes Cluster
- AWS IAM Permissions for creating and attaching IAM Roles
- Installation of required tools:
  - [AWS CLI](https://aws.amazon.com/cli/)
  - [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl)
  - [Terraform](https://learn.hashicorp.com/tutorials/terraform/install-cli#install-terraform)
  - [eksctl](https://docs.aws.amazon.com/eks/latest/userguide/eksctl.html)

## Installation

If you don't have an Amazon EKS cluster, you can use the Terraform code in [cluster folder](./cluster/) to deploy one. This Terraform code creates the following resources:

- A VPC with three private and three public subnets,
- An Amazon EKS Cluster with Kubernetes version set to 1.28 and a Managed Node Group with one instance,
- Some EKS and Custom Addons such as [Karpenter](karpenter.sh) and [External Secrets Operator](https://external-secrets.io/latest/),
- Required IAM Roles for Addons and the AWS Gateway API Controller.

> You can update the Terraform codes according to your requirements and environment.

### Installation of EKS Cluster

```shell
terraform init
terraform plan
terraform apply --auto-approve
```

> PS:
>
> - These resources are not Free Tier eligible.
> - You need to configure AWS Authentication for Terraform with either [Environment Variables](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-envvars.html#envvars-set) or AWS CLI [named profiles](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-profiles.html#cli-configure-profiles-create).

You can connect to your cluster using this command:

```bash
aws eks --region <region> update-kubeconfig --name <cluster_name>
```

> You need to change `region` and `cluster_name` parameters.

### Installation of example application

You can find the Kubernetes manifests for an e-commerce application that consists of seven microservices in the [example-application](./example-application/) folder. [Kustomize](https://kustomize.io/) can be used to deploy the entire application stack.

```bash
kubectl apply -k example-application/
```

> The service object of the UI service creates a Network Load Balancer.

### Installation of the AWS Gateway API Controller

When you want to install the AWS Gateway API Controller and configure the Security Group access you can run `./vpc-lattice/.installation.sh`.

The [script](./vpc-lattice/installation.sh) has one function called install.

- Install function configures the Security Group authorisation and installs the required AWS Gateway API Controller Helm Chart to the Kubernetes cluster.

```bash
kubectl get deployment -n gateway-api-controller
NAME                                                  READY   UP-TO-DATE   AVAILABLE   AGE
gateway-api-controller-aws-gateway-controller-chart   2/2     2            2           24s
```

## VPC Lattice Configuration

In the [vpc-lattice](./vpc-lattice/) folder you can find the resources for the controller. First you need to install the [Gateway Class](./vpc-lattice/controller/gatewayclass.yaml) and the [Gateway](./vpc-lattice/controller/gateway.yaml).

```bash
kubectl apply -f vpc-lattice/controller/gatewayclass.yaml
kubectl apply -f vpc-lattice/controller/gateway.yaml
```

```bash
kubectl get gateway -n checkout
NAME                CLASS                ADDRESS   PROGRAMMED   AGE
eks-cluster         amazon-vpc-lattice             True         29s
```

Wait until the status is `Reconciled` (this could take about five minutes).

```bash
kubectl wait --for=condition=Programmed gateway/eks-cluster -n checkout
```

There is also a v2 of the Checkout microservice with a minor change. The definitions for the v2 Checkout service are in [applicationv2](./vpc-lattice/applicationv2/). In this example, we will route the traffic with VPC Lattice between v1 and v2 of the Checkout service.

```bash
kubectl apply -k vpc-lattice/applicationv2/
kubectl rollout status deployment/checkout -n checkoutv2
```

Now it's time to actually deploy the `HTTPRoute` resource.

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: checkoutroute
  namespace: checkout
spec:
  parentRefs:
  - name: eks-cluster
    sectionName: http 
  rules:
  - backendRefs:  
    - name: checkout
      namespace: checkout
      kind: Service
      port: 80
      weight: 25
    - name: checkout
      namespace: checkoutv2
      kind: Service
      port: 80
      weight: 75
```

As you can see, the [Checkout Route Manifest](./vpc-lattice/controller/checkout-route.yaml) distributes 75% traffic to `checkoutv2` and remaining 25% traffic to `checkout`. There is also a [Target Group Policy](./vpc-lattice/controller/target-group-policy.yaml) manifest that defines the Target Group behaviour.

```bash
kubectl apply -f vpc-lattice/controller/checkout-route.yaml
kubectl apply -f vpc-lattice/controller/target-group-policy.yaml
```

This creation of the associated resources may take 2-3 minutes, run the following command to wait for it to complete:

```bash
kubectl wait --for=jsonpath='{.status.parents[-1:].conditions[-1:].reason}'=ResolvedRefs httproute/checkoutroute -n checkout
```

Once completed you will find the `HTTPRoute`'s DNS name from `HTTPRoute` status.

```bash
kubectl describe httproute checkoutroute -n checkout
```

You can see the DNS name with this command:

```bash
kubectl get httproute checkoutroute -n checkout -o json | jq -r '.metadata.annotations["application-networking.k8s.aws/lattice-assigned-domain-name"]'
```

Finally you need to update the [ConfigMap](./example-application/ui/configmap.yaml) of the UI service to update the DNS name for the Checkout service.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ui
  namespace: ui
data:
  ENDPOINTS_CHECKOUT: http://<NEW DNS ADDRESS FOR THE CHECKOUT SERVICE>
...
```

After restarting the UI service deployment, you should be able to see the updated version of the Checkout service.

```bash
kubectl rollout restart deployment/ui -n ui
```
