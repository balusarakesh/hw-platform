output "cluster_name" {
  value = module.eks.cluster_name
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region} --profile ${var.aws_profile}"
}

output "node_group_name" {
  value = module.eks.eks_managed_node_groups["general"].node_group_id
}
