terraform {
  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.2.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.44.0"
    }
  }
  required_version = ">= 0.13.0"
}

/*
 * == Install and Configure CloudWatch Agent
 *
 * Automatically install and configure a CloudWatch agent on the instance.
 */
module "cloudwatch_agent" {
  for_each            = var.instances

  source              = "github.com/nsbno/terraform-aws-ssm-managed-instance?ref=a37be758/modules/cloudwatch-agent"

  name_prefix         = var.name_prefix
  metric_namespace    = var.ecs_cluster_name
  instance_identifier = each.key
  instance_targets    = [
    {
      key    = "tag:instance-name"
      values = [each.key]
    }
  ]

  tags                = var.tags
}

/*
 * == SSM Activation
 *
 * This is how we register the host with SSM.
 */
resource "aws_kms_key" "ssm_activation_encryption_key" {
  description   = "Key used for encrypting SSM activation ID and code in Parameter Store."
  tags          = var.tags
}
resource "aws_kms_alias" "ssm_activation_encryption_key_alias" {
  target_key_id = aws_kms_key.ssm_activation_encryption_key.key_id
  name          = "alias/${var.name_prefix}-ssm_activation_key_encryption"
}

module "instance" {
  for_each      = var.instances

  source        = "github.com/nsbno/terraform-aws-ssm-managed-instance?ref=0d6c82e"

  name_prefix   = var.name_prefix
  instance_name = each.key
  kms_arn       = aws_kms_key.ssm_activation_encryption_key.arn

  policy_arns   = [
    # Managed policy required by the ECS agent
    "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
  ]
  policy_statements = [
    # Policies required by the CloudWatch agent
    {
      effect    = "Allow"
      actions   = ["ssm:GetParameter"],
      resources = [module.cloudwatch_agent[each.key].ssm_parameter_arn]
    },
    {
      effect    = "Allow"
      actions   = ["logs:CreateLogStream", "logs:PutLogEvents"],
      resources = ["${module.cloudwatch_agent[each.key].log_group_arn}:*"]
    },
    {
      effect    = "Allow"
      actions   = ["cloudwatch:PutMetricData"],
      resources = ["*"]
      condition = [
        {
          test     = "StringEquals"
          variable = "cloudwatch:namespace"
          values   = [module.cloudwatch_agent[each.key].metric_namespace]
        }
      ]
    }
  ]

  tags = var.tags
}

data "aws_region" "current" {}

resource "null_resource" "configure_instance" {
  for_each = var.configure_instances ? var.instances : {}

  connection {
    type = "ssh"
    user = each.value.username
    password = each.value.password
    host = each.value.host
  }

  provisioner "remote-exec" {
    inline = [
      # We ignore any lines of history that have this pattern,
      # as it will include the user's password.
      "export HISTIGNORE='*sudo -S -k*'",

      # Get dependencies ready
      # This assumes that we're running on RHEL 7 (which Vy hosts are).
      "echo ${each.value.password} | sudo -S -k subscription-manager repos --enable=rhel-7-server-rpms --enable=rhel-7-server-extras-rpms --enable=rhel-7-server-optional-rpms",
      "echo ${each.value.password} | sudo -S -k yum install -y yum-utils device-mapper-persistent-data lvm2",
      "echo ${each.value.password} | sudo -S -k yum install -y https://mirror.centos.org/centos/7/extras/x86_64/Packages/container-selinux-2.107-3.el7.noarch.rpm",
      "echo ${each.value.password} | sudo -S -k yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo",
      "echo ${each.value.password} | sudo -S -k yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm",
      "echo ${each.value.password} | sudo -S -k yum install -y docker-ce docker-ce-cli containerd.io",

      # Do the actual install!
      "curl --proto https -o /tmp/ecs-anywhere-install.sh 'https://raw.githubusercontent.com/aws/amazon-ecs-init/v1.53.0-1/scripts/ecs-anywhere-install.sh'",
      "echo '5ea39e5af247b93e77373c35530d65887857b8d14539465fa7132d33d8077c8c  /tmp/ecs-anywhere-install.sh' | sha256sum -c - || exit 1",
      "echo ${each.value.password} | sudo -S -k bash /tmp/ecs-anywhere-install.sh --docker-install-source none --region '${data.aws_region.current.name}' --cluster '${var.ecs_cluster_name}' --activation-id '${module.instance[each.key].activation_id}' --activation-code '${module.instance[each.key].activation_code}'"
    ]
  }
}

/*
 * == Setup Monitoring for SSM and ECS Agents
 */
module "agent_connectivity" {
  source      = "github.com/nsbno/terraform-aws-ssm-managed-instance?ref=a37be758/modules/agent-connectivity"

  name_prefix = var.name_prefix
  tags        = var.tags
}

resource "aws_lambda_permission" "cloudwatch_allow_invoke" {
  action        = "lambda:InvokeFunction"
  function_name = module.agent_connectivity.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.invoke_connectivity_lambda.arn
}

resource "aws_cloudwatch_event_rule" "invoke_connectivity_lambda" {
  description         = "Periodically monitor the connection status of SSM and ECS agents running on managed instances."
  schedule_expression = "rate(1 minute)"
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "agent" {
  arn = module.agent_connectivity.function_arn
  input = jsonencode({
    ecs_cluster = var.ecs_cluster_name
  })
  rule = aws_cloudwatch_event_rule.invoke_connectivity_lambda.name
}

/*
 * == Register Alarms for Each Instance
 */
resource "aws_cloudwatch_metric_alarm" "ssm_agent" {
  for_each          = var.instances

  alarm_name        = "${module.instance[each.key].instance_name}-ssm-agent"
  alarm_description = "Triggers if AWS has lost connection to the SSM agent on an instance named '${module.instance[each.key].instance_name}' (e.g., due to network outage, instance downtime, etc.)"
  namespace         = module.agent_connectivity.metric_namespace
  metric_name       = module.agent_connectivity.metric_names.ssm_agent_disconnected
  dimensions = {
    InstanceName = module.instance[each.key].instance_name
  }

  statistic                 = "SampleCount"
  period                    = 60
  insufficient_data_actions = []
  alarm_actions             = var.alarms_sns_topic_arns
  ok_actions                = var.alarms_sns_topic_arns
  comparison_operator       = "GreaterThanThreshold"
  treat_missing_data        = "notBreaching"
  threshold                 = 0
  evaluation_periods        = 1
  datapoints_to_alarm       = 1
  tags                      = var.tags
}

resource "aws_cloudwatch_metric_alarm" "ecs_agent" {
  for_each          = var.instances

  alarm_name        = "${module.instance[each.key].instance_name}-ecs-agent"
  alarm_description = "Triggers if AWS has lost connection to the ECS agent on an instance named '${module.instance[each.key].instance_name}' (e.g., due to network outage, instance downtime, etc.)"
  namespace         = module.agent_connectivity.metric_namespace
  metric_name       = module.agent_connectivity.metric_names.ecs_agent_disconnected
  dimensions = {
    InstanceName = module.instance[each.key].instance_name
  }

  statistic                 = "SampleCount"
  period                    = 60
  insufficient_data_actions = []
  alarm_actions             = var.alarms_sns_topic_arns
  ok_actions                = var.alarms_sns_topic_arns
  comparison_operator       = "GreaterThanThreshold"
  treat_missing_data        = "notBreaching"
  threshold                 = 0
  evaluation_periods        = 1
  datapoints_to_alarm       = 1
  tags                      = var.tags
}
