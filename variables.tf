variable "name_prefix" {
  description = "A prefix to add to the names the created resources"
  type = string
}

variable "ecs_cluster_name" {
  description = "The cluster that you want to register your instance(s) to"
  type = string
}

variable "instances" {
  description = "A set of instance names. If configure_instances is true it has to be a map."
  type = any
}

variable "alarms_sns_topic_arns" {
  description = "SNS Topics to send alarms to (if any)"
  type = list(string)
  default = []
}

variable "configure_instances" {
  description = "If the module should configure each instance for you. This requires that you run locally with VPN on the first apply."
  type = bool
  default = false
}

variable "tags" {
  description = "Any tags you might want to add to the alarms, instances and more"
  type = any
  default = {}
}
