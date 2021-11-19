variable "ecs_cluster_name" {
  description = "The cluster that you want to register your instance(s) to"
  type = string
}

variable "instance_names" {
  description = "A list of names for instances"
  type = list(string)
}

variable "name_prefix" {
  description = "A prefix to add to the names the created resources"
  type = string
}

variable "tags" {
  description = "Any tags you might want to add to the alarms, instances and more"
  type = any
  default = {}
}

variable "alarms_sns_topic_arns" {
  description = "SNS Topics to send alarms to (if any)"
  type = list(string)
  default = []
}