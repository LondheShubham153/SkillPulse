variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "skillpulse"
}

variable "cluster_version" {
  description = "Kubernetes version. Verify availability with `aws eks describe-addon-versions --kubernetes-version <ver> --region <region>` before applying."
  type        = string
  default     = "1.32"
}

variable "node_instance_type" {
  description = "EC2 instance type for the managed node group"
  type        = string
  default     = "t3.large"
}
