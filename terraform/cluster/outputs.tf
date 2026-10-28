output "cluster_name" {
  value = module.eks.cluster_name
}

output "kubeconfig_command" {
  # The profile is appended only when set (Atlantis runs with an empty profile).
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}${var.aws_profile == "" ? "" : " --profile ${var.aws_profile}"}"
}

output "node_group_name" {
  value = module.eks.eks_managed_node_groups["general"].node_group_id
}
