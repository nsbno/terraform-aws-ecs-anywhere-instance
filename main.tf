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
  required_version = ">= 1.0.0"
}

/*
 * == Install and Configure CloudWatch Agent
 *
 * Automatically install and configure a CloudWatch agent on the instance.
 */
module "cloudwatch_agent" {
  for_each            = var.instance_names

  source              = "github.com/nsbno/terraform-aws-ssm-managed-instance?ref=3185875/modules/cloudwatch-agent"

  name_prefix         = var.name_prefix
  metric_namespace    = var.ecs_cluster_name
  instance_identifier = each.value
  instance_targets    = [
    {
      key    = "tag:instance-name"
      values = [each.value]
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
  for_each      = var.instance_names

  source        = "github.com/nsbno/terraform-aws-ssm-managed-instance?ref=3185875"

  name_prefix   = var.name_prefix
  instance_name = each.value
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
      resources = [module.cloudwatch_agent[each.value].ssm_parameter_arn]
    },
    {
      effect    = "Allow"
      actions   = ["logs:CreateLogStream", "logs:PutLogEvents"],
      resources = ["${module.cloudwatch_agent[each.value].log_group_arn}:*"]
    },
    {
      effect    = "Allow"
      actions   = ["cloudwatch:PutMetricData"],
      resources = ["*"]
      condition = [
        {
          test     = "StringEquals"
          variable = "cloudwatch:namespace"
          values   = [module.cloudwatch_agent[each.value].metric_namespace]
        }
      ]
    }
  ]

  tags = var.tags
}

/*
 * == Setup Monitoring for SSM and ECS Agents
 */
module "agent_connectivity" {
  source      = "github.com/nsbno/terraform-aws-ssm-managed-instance?ref=3185875/modules/agent-connectivity"

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
  for_each          = var.instance_names

  alarm_name        = "${module.instance[each.value].instance_name}-ssm-agent"
  alarm_description = "Triggers if AWS has lost connection to the SSM agent on an instance named '${module.instance[each.value].instance_name}' (e.g., due to network outage, instance downtime, etc.)"
  namespace         = module.agent_connectivity.metric_namespace
  metric_name       = module.agent_connectivity.metric_names.ssm_agent_disconnected
  dimensions = {
    InstanceName = module.instance[each.value].instance_name
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
  for_each          = var.instance_names

  alarm_name        = "${module.instance[each.value].instance_name}-ecs-agent"
  alarm_description = "Triggers if AWS has lost connection to the ECS agent on an instance named '${module.instance[each.value].instance_name}' (e.g., due to network outage, instance downtime, etc.)"
  namespace         = module.agent_connectivity.metric_namespace
  metric_name       = module.agent_connectivity.metric_names.ecs_agent_disconnected
  dimensions = {
    InstanceName = module.instance[each.value].instance_name
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
