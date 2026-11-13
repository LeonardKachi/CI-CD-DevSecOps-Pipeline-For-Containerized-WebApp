variable "project" {
  description = "Short project name used in resource names."
  type        = string
}

variable "vpc_id" {
  description = "VPC the security groups belong to."
  type        = string
}

variable "alb_port" {
  description = "Port the load balancer listens on. Plain HTTP for now, see the README for the HTTPS upgrade."
  type        = number
  default     = 80
}

variable "app_port" {
  description = "Port the application container listens on. Must match the Dockerfile and nginx.conf."
  type        = number
  default     = 8080
}

variable "alb_ingress_cidrs" {
  description = "Who may reach the load balancer. Open to the internet by default. Set it to your own IP range to lock the site down while testing."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
