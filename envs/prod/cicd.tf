# ---------- CD: GitHub Actions → ECR → SSM 배포 ----------
# 서비스 레포의 main에 push(develop → main 머지)되면 Infra의 공통 워크플로(.github/workflows/deploy-service.yaml)가
# 이미지를 빌드해 ECR에 올리고 SSM release 태그를 바꾼 뒤, 해당 풀 서버에 한 대씩 다시 배포합니다.
# AWS 키를 GitHub에 저장하지 않고 OIDC로 짧은 자격 증명만 받습니다. 역할은 레포마다 하나이며 자기 서비스만 다룹니다.

variable "github_org" {
  description = "배포를 허용할 GitHub 조직입니다."
  type        = string
  default     = "sw-academy-msa"
}

variable "github_org_id" {
  description = "GitHub 조직의 고유 ID입니다. 레포가 immutable subject를 쓰면 OIDC sub에 이름과 함께 ID가 들어갑니다."
  type        = number
  default     = 341201926
}

variable "create_github_oidc_provider" {
  description = "계정에 GitHub OIDC 공급자가 이미 있으면 false로 두고 기존 것을 씁니다(계정당 하나만 만들 수 있음)."
  type        = bool
  default     = true
}

locals {
  # GitHub 레포 이름 → ECR 저장소(서비스) 이름, 배포할 풀, 레포 고유 ID입니다. 레포 이름은 GitHub에 있는 그대로입니다.
  # repo_id는 `gh api repos/<조직>/<레포> --jq .id`로 확인합니다.
  deploy_targets = {
    AccountService        = { service = "account-service", pool = "general", repo_id = 1429700003 }
    ProductQueryService   = { service = "product-query-service", pool = "general", repo_id = 1442004312 }
    OrderQueryService     = { service = "order-query-service", pool = "general", repo_id = 1446824605 }
    PaymentService        = { service = "payment-service", pool = "general", repo_id = 1444060449 }
    AIService             = { service = "ai-service", pool = "general", repo_id = 1450068754 }
    NotificationService   = { service = "notification-service", pool = "general", repo_id = 1452173067 }
    GeneralGateway        = { service = "gateway", pool = "general", repo_id = 1433374354 }
    Eureka                = { service = "eureka", pool = "general", repo_id = 1433312560 }
    ProductCommandService = { service = "product-command-service", pool = "purchase", repo_id = 1440682142 }
    OrderCommandService   = { service = "order-command-service", pool = "purchase", repo_id = 1442519946 }
    PurchaseGateway       = { service = "purchase-gateway", pool = "purchase", repo_id = 1440864967 }
  }
  github_oidc_host = "token.actions.githubusercontent.com"
  github_oidc_arn  = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_github_oidc_provider ? 1 : 0
  url            = "https://${local.github_oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://${local.github_oidc_host}"
}

# main 브랜치에서 실행된 그 레포의 워크플로만 역할을 받을 수 있습니다. PR·다른 브랜치·다른 레포는 거부됩니다.
data "aws_iam_policy_document" "deploy_assume" {
  for_each = local.deploy_targets
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:sub"
      # 레포 OIDC 설정이 immutable subject(이름@ID)면 둘째 값, 기본 형식이면 첫째 값으로 옵니다. 둘 다 그 레포의 main만 허용합니다.
      values = [
        "repo:${var.github_org}/${each.key}:ref:refs/heads/main",
        "repo:${var.github_org}@${var.github_org_id}/${each.key}@${each.value.repo_id}:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "deploy" {
  for_each             = local.deploy_targets
  name                 = "${var.name}-deploy-${each.value.service}"
  description          = "GitHub Actions CD for ${var.github_org}/${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.deploy_assume[each.key].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "deploy" {
  for_each = local.deploy_targets

  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  # 자기 서비스 저장소에만 push합니다. 태그 덮어쓰기는 저장소 설정이 막습니다.
  statement {
    sid = "EcrPushOwnRepository"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages",
    ]
    resources = [module.ecr.repository_arn_map[each.value.service]]
  }
  # 자기 서비스의 배포 태그만 읽고 바꿉니다. 다른 설정·비밀값은 읽지 못합니다.
  statement {
    sid       = "ReleaseTag"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.parameter_path}/release/${each.value.service}"]
  }
  # Run Command는 AWS-RunShellScript 문서로, 자기 풀(Pool 태그) 서버에만 보냅니다.
  statement {
    sid       = "RunCommandDocument"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.region}::document/AWS-RunShellScript"]
  }
  statement {
    sid       = "RunCommandOwnPool"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Pool"
      values   = [each.value.pool]
    }
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Project"
      values   = ["STOCKDROP"]
    }
  }
  # 보낸 명령의 결과 조회와, 시간 안에 끝나지 않은 명령 취소입니다. 리소스로 좁힐 수 없습니다.
  statement {
    sid       = "RunCommandResult"
    actions   = ["ssm:ListCommands", "ssm:ListCommandInvocations", "ssm:GetCommandInvocation", "ssm:CancelCommand"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  for_each = local.deploy_targets
  name     = "deploy"
  role     = aws_iam_role.deploy[each.key].id
  policy   = data.aws_iam_policy_document.deploy[each.key].json
}

output "deploy_roles" {
  description = "레포별 CD 역할입니다. 이름 규칙은 <name>-deploy-<서비스>이며, 워크플로는 조직 변수 AWS_ACCOUNT_ID로 ARN을 만듭니다."
  value       = { for k, r in aws_iam_role.deploy : k => r.arn }
}

# GitHub 레포 이름이 OderQueryService → OrderQueryService로 바뀌었습니다. OIDC는 현재 이름을 보내므로 키를 옮기고,
# 같은 이름의 역할을 지우고 다시 만들지 않도록 상태만 옮깁니다.
moved {
  from = aws_iam_role.deploy["OderQueryService"]
  to   = aws_iam_role.deploy["OrderQueryService"]
}

moved {
  from = aws_iam_role_policy.deploy["OderQueryService"]
  to   = aws_iam_role_policy.deploy["OrderQueryService"]
}

# ---------- 모니터링 CD: Monitoring 레포 main → 모니터링 EC2 설정 갱신 ----------
# 이미지를 만들지 않고 공식 이미지를 쓰므로 ECR 권한이 없습니다. 모니터링 EC2(Role=monitoring)에 원격 명령만 보냅니다.
locals {
  monitoring_repo = { name = "Monitoring", repo_id = 1452190910 }
}

data "aws_iam_policy_document" "deploy_monitoring_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:sub"
      values = [
        "repo:${var.github_org}/${local.monitoring_repo.name}:ref:refs/heads/main",
        "repo:${var.github_org}@${var.github_org_id}/${local.monitoring_repo.name}@${local.monitoring_repo.repo_id}:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "deploy_monitoring" {
  name                 = "${var.name}-deploy-monitoring"
  description          = "GitHub Actions CD for ${var.github_org}/${local.monitoring_repo.name}"
  assume_role_policy   = data.aws_iam_policy_document.deploy_monitoring_assume.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "deploy_monitoring" {
  statement {
    sid       = "RunCommandDocument"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.region}::document/AWS-RunShellScript"]
  }
  statement {
    sid       = "RunCommandMonitoringHost"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Role"
      values   = ["monitoring"]
    }
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Project"
      values   = ["STOCKDROP"]
    }
  }
  # 대상 EC2 조회와 명령 결과 확인·취소입니다. 조회는 리소스로 좁힐 수 없습니다.
  statement {
    sid       = "ReadAndCancel"
    actions   = ["ec2:DescribeInstances", "ssm:ListCommands", "ssm:ListCommandInvocations", "ssm:GetCommandInvocation", "ssm:CancelCommand"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy_monitoring" {
  name   = "deploy"
  role   = aws_iam_role.deploy_monitoring.id
  policy = data.aws_iam_policy_document.deploy_monitoring.json
}

output "deploy_monitoring_role" {
  description = "Monitoring 레포 CD 역할입니다."
  value       = aws_iam_role.deploy_monitoring.arn
}
