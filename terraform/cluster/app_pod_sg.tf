# Security group for the hello-world pods (attached per pod by a SecurityGroupPolicy in the chart).
# Only these pods can reach Aurora; other pods on the same nodes can't, even though they share the node SG.
#
# With POD_SECURITY_GROUP_ENFORCING_MODE=standard, traffic leaving the VPC (STS, AWS APIs) is SNATed to
# the node and governed by the node SG; this SG governs in-VPC traffic to and from the pods.

resource "aws_security_group" "app_pods" {
  name        = "${var.project}-app-pods"
  description = "hello-world pods (security groups for pods)"
  vpc_id      = local.p.vpc_id

  tags = {
    Name = "${var.project}-app-pods"
    # Lets the AWS Load Balancer Controller add its ALB backend-SG ingress rule to this SG for
    # target-type ip (it only manages SGs tagged for the cluster).
    "kubernetes.io/cluster/${var.project}" = "owned"
  }
}

# Kubelet probes and the Prometheus scraper (pods on the node SG) reach the app and metrics ports.
resource "aws_vpc_security_group_ingress_rule" "app_pods_from_nodes" {
  for_each = { http = 8080, metrics = 9090 }

  security_group_id            = aws_security_group.app_pods.id
  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  description                  = "${each.key} from nodes (probes, scraper)"
}

resource "aws_vpc_security_group_egress_rule" "app_pods_to_aurora" {
  security_group_id            = aws_security_group.app_pods.id
  referenced_security_group_id = local.p.aurora_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = local.p.aurora_port
  to_port                      = local.p.aurora_port
  description                  = "Postgres to Aurora"
}

# DNS (CoreDNS pods use the node SG) and in-VPC HTTPS (EKS API endpoint ENIs).
resource "aws_vpc_security_group_egress_rule" "app_pods_dns" {
  for_each = toset(["udp", "tcp"])

  security_group_id            = aws_security_group.app_pods.id
  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = each.value
  from_port                    = 53
  to_port                      = 53
  description                  = "DNS to CoreDNS (${each.value})"
}

resource "aws_vpc_security_group_egress_rule" "app_pods_https_vpc" {
  security_group_id = aws_security_group.app_pods.id
  cidr_ipv4         = local.p.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS inside the VPC"
}

# Aurora: accept the app pods' SG. The node-SG rule (eks.tf) stays so nothing breaks before the
# SecurityGroupPolicy is rolled out; removing it is a follow-up once pods carry this SG.
resource "aws_vpc_security_group_ingress_rule" "rds_from_app_pods" {
  security_group_id            = local.p.aurora_security_group_id
  referenced_security_group_id = aws_security_group.app_pods.id
  ip_protocol                  = "tcp"
  from_port                    = local.p.aurora_port
  to_port                      = local.p.aurora_port
  description                  = "Postgres from hello-world pods"
}
