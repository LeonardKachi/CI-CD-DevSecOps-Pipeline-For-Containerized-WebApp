# Root module: wires the building blocks together.
#
# Reading order follows the dependency order:
#   kms, network, security   foundations: encryption, network, firewall rules
#   ecr, alb                 where images live, and the public entry point
#   ecs                      runs the app
#   monitoring               dashboard and alarms
#   jenkins                  the CI/CD server that deploys to all of the above

module "kms" {
  source = "./modules/kms"

  project = var.project

  # A short wait makes teardown practical. Real use keeps the full 30 days, which
  # is the safety net against deleting a key by mistake.
  deletion_window_in_days = var.allow_teardown ? 7 : 30
}

module "network" {
  source = "./modules/network"

  project     = var.project
  kms_key_arn = module.kms.key_arn
}

module "security" {
  source = "./modules/security"

  project           = var.project
  vpc_id            = module.network.vpc_id
  alb_ingress_cidrs = var.alb_ingress_cidrs
}

module "ecr" {
  source = "./modules/ecr"

  repository_name = var.project
  kms_key_arn     = module.kms.key_arn
  force_delete    = var.allow_teardown

  # The two locks on the registry: only the pipeline can push, and only the
  # pipeline and the running service can pull. The roles come from the modules
  # that are built from this repository, which is fine: the repository itself
  # needs nothing from them. Only its access policy does.
  push_principal_arns = [module.jenkins.role_arn]
  pull_principal_arns = [module.ecs.execution_role_arn]
}

module "alb" {
  source = "./modules/alb"

  project                    = var.project
  vpc_id                     = module.network.vpc_id
  public_subnet_ids          = module.network.public_subnet_ids
  alb_security_group_id      = module.security.alb_security_group_id
  enable_deletion_protection = !var.allow_teardown
  force_destroy_log_bucket   = var.allow_teardown
}

module "ecs" {
  source = "./modules/ecs"

  project                 = var.project
  private_subnet_ids      = module.network.private_app_subnet_ids
  app_security_group_id   = module.security.app_security_group_id
  target_group_arn        = module.alb.target_group_arn
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  repository_url          = module.ecr.repository_url
  repository_arn          = module.ecr.repository_arn
  kms_key_arn             = module.kms.key_arn
  min_capacity            = var.min_capacity
  max_capacity            = var.max_capacity

  # The service can only be created once the load balancer listener exists.
  depends_on = [module.alb]
}

module "monitoring" {
  source = "./modules/monitoring"

  project                 = var.project
  kms_key_arn             = module.kms.key_arn
  alert_email             = var.alert_email
  alb_arn_suffix          = module.alb.alb_arn_suffix
  target_group_arn_suffix = module.alb.target_group_arn_suffix
  cluster_name            = module.ecs.cluster_name
  service_name            = module.ecs.service_name
  log_group_name          = module.ecs.log_group_name
}

module "jenkins" {
  source = "./modules/jenkins"

  project                = var.project
  subnet_id              = module.network.private_tooling_subnet_id
  security_group_id      = module.security.jenkins_security_group_id
  kms_key_arn            = module.kms.key_arn
  ecr_repository_name    = module.ecr.repository_name
  ecr_repository_arn     = module.ecr.repository_arn
  ecs_cluster_name       = module.ecs.cluster_name
  ecs_service_name       = module.ecs.service_name
  ecs_service_arn        = module.ecs.service_arn
  ecs_task_role_arns     = [module.ecs.execution_role_arn, module.ecs.task_role_arn]
  alb_name               = module.alb.alb_name
  github_repo_url        = var.github_repo_url
  github_branch          = var.github_branch
  github_token_parameter = var.github_token_parameter
  instance_type          = var.jenkins_instance_type

  # The server installs its software on first boot, so it needs the internet
  # path (NAT gateway and routes) and its firewall rules to exist before it
  # starts. Passing the subnet and group IDs alone would not guarantee that.
  depends_on = [module.network, module.security]
}
