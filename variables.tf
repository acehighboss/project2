variable "db_username" {
  type = string
}
variable "db_password" {
  type = string
}
# [추가] Bastion Host에 접속할 관리자 IP
variable "admin_ip" {
  type        = string
  description = "My (Admin) IP address for SSH access to the bastion host."
}