resource "aws_ecs_cluster" "cluster" {
  name = "my-cluster"
}

data "aws_ssm_parameter" "username" {
  name = "onprem/linuxserver449/username"
}

data "aws_ssm_parameter" "password" {
  name = "onprem/linuxserver449/password"
}

module "ecs_instance" {
  source = "../../"

  name_prefix = "demo"

  ecs_cluster_name = aws_ecs_cluster.cluster.name

  configure_instances = true
  instances = {
    linuxserver449 = {
      host = "127.0.0.1"
      username = data.aws_ssm_parameter.username.value
      password = data.aws_ssm_parameter.password.value
    }
  }
}