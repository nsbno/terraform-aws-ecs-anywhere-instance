resource "aws_ecs_cluster" "cluster" {
  name = "my-cluster"
}

module "on_prem_ecs_instance" {
  source = "../../"

  name_prefix      = "demo"
  ecs_cluster_name = aws_ecs_cluster.cluster.name
  instances        = ["linuxserver449"]
}

