variable "domain_name" {
  description = "対象のメインドメイン名"
  type        = string
  default     = "taiga-miura.com"
}

variable "dns_delegation_completed" {
  description = "外部レジストラ側で Route 53 の NS 委譲が完了しているか"
  type        = bool
  default     = false
}
