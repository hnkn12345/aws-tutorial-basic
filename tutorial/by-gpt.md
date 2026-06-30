# Terraform + AWS + CI/CD で学ぶ Web デプロイ基礎チュートリアル

## オンプレ・組み込み出身ジュニア向け AWS 実践入門

---

## 0. このチュートリアルのゴール

このチュートリアルでは、AWS の基本概念と、Terraform によるインフラ管理、CI/CD によるアプリケーションデプロイ、Blue/Green デプロイを一つの流れで学びます。

対象読者は、オンプレミス環境や組み込み開発の経験はあるが、AWS やクラウドの Web デプロイにはまだ慣れていないジュニアエンジニアです。

最終ゴールは、次の流れを実際に体験することです。

```text
1. Terraform で AWS 上に Web アプリ実行基盤を作る
2. GitHub Actions でアプリをテストする
3. テストに通ったらアプリをビルドする
4. 成果物を S3 にアップロードする
5. CodeDeploy で EC2 にデプロイする
6. v1 から v2 へアプリをバージョンアップする
7. Blue/Green デプロイの考え方を理解する
8. 失敗時にロールバックできる理由を理解する
```

---

# 1. 先に全体像をつかむ

## 1-1. 最終的に作る構成

このチュートリアルでは、最終的に以下のような構成を目指します。

```text
GitHub Repository
    |
    | git push
    v
GitHub Actions
    |
    | test / build / package
    v
S3 Artifact Bucket
    |
    | deploy request
    v
AWS CodeDeploy
    |
    | deploy app
    v
Auto Scaling Group
    |
    v
EC2 Instances
    ^
    |
Application Load Balancer
    ^
    |
Internet
```

もう少し AWS リソース寄りに書くと、以下です。

```text
Internet
  |
  v
ALB
  |
  v
Target Group
  |
  v
Auto Scaling Group
  |
  v
EC2 Amazon Linux 2023
  |
  v
tutorial-app
```

Terraform は、この土台を作ります。

```text
Terraform が管理するもの:
  - VPC
  - Subnet
  - Internet Gateway
  - Route Table
  - Security Group
  - IAM Role
  - S3 Artifact Bucket
  - ALB
  - Target Group
  - Launch Template
  - Auto Scaling Group
  - CodeDeploy Application
  - CodeDeploy Deployment Group
  - GitHub Actions 用 OIDC Role
```

一方、アプリのリリースは CI/CD が担当します。

```text
CI/CD が担当するもの:
  - テスト
  - ビルド
  - zip 作成
  - S3 へのアップロード
  - CodeDeploy の実行
  - デプロイ結果確認
```

ここが非常に重要です。

**Terraform はインフラを管理する道具であり、アプリを毎回リリースする道具ではありません。**

アプリの v1 から v2 への更新を毎回 `terraform apply` でやる構成は、このチュートリアルの趣旨から外れます。

---

# 2. オンプレ経験者向け AWS 概念対応表

AWS の概念は、オンプレの設備に置き換えると理解しやすくなります。

| オンプレの感覚            | AWS の用語            | ざっくり説明                |
| ------------------ | ------------------ | --------------------- |
| データセンターの地域         | Region             | 東京、シンガポール、バージニア北部など   |
| 別棟・別電源の設備          | Availability Zone  | 同一リージョン内の独立した設備       |
| 社内ネットワーク           | VPC                | AWS 内に作る自分専用ネットワーク    |
| VLAN / ネットワークセグメント | Subnet             | VPC を分割したネットワーク       |
| ルーターの経路表           | Route Table        | 通信の行き先を決める表           |
| インターネット出口          | Internet Gateway   | VPC からインターネットへ出るための出口 |
| ホスト前のFW            | Security Group     | EC2 などに付けるステートフルな仮想FW |
| 仮想サーバー             | EC2 Instance       | AWS 上の仮想マシン           |
| OSイメージ             | AMI                | EC2 の起動元イメージ          |
| L7ロードバランサ          | ALB                | HTTP/HTTPS の入口        |
| 振り分け先サーバー一覧        | Target Group       | ALB が通信を流す先の集まり       |
| サーバー台数維持           | Auto Scaling Group | 指定台数の EC2 を維持する仕組み    |
| 権限管理               | IAM                | 人・サービス・プログラムの権限管理     |
| デプロイツール            | CodeDeploy         | アプリを EC2 などに配布する仕組み   |
| Jenkins など         | GitHub Actions     | CI/CD 実行環境            |
| リリース成果物置き場         | S3                 | zip などを置くオブジェクトストレージ  |

---

# 3. この教材での学習順

いきなり Blue/Green に行くと難しいため、段階的に進めます。

## Phase 1: AWS と Terraform の基礎

最初は、Terraform で最小構成を作ります。

```text
VPC
Public Subnet
Internet Gateway
Route Table
Security Group
EC2
```

目的は、AWS の基本部品を理解することです。

この段階では、アプリデプロイのベストプラクティスよりも、まず AWS の部品同士のつながりを理解します。

---

## Phase 2: EC2 上で簡単な Web アプリを動かす

Apache の固定 HTML ではなく、自作の簡単な Web アプリを動かします。

アプリは Go で作ります。

理由は、単一バイナリにでき、組み込み出身者にも「実行ファイルを置いて systemd で動かす」という感覚で理解しやすいからです。

アプリの仕様:

```text
GET /        -> Hello from tutorial app v1
GET /health  -> OK
GET /version -> v1
```

---

## Phase 3: GitHub Actions で CI を作る

GitHub に push したら、自動でテストを実行します。

```text
git push
  |
  v
GitHub Actions
  |
  v
go test ./...
```

この段階では、まだ AWS へデプロイしません。

目的は、CI の基本を理解することです。

---

## Phase 4: GitHub Actions から AWS へ接続する

GitHub Actions から AWS を操作するため、OIDC を使います。

古いやり方では、GitHub Secrets に次を保存していました。

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

このチュートリアルでは、この方式を避けます。

代わりに、GitHub Actions が AWS IAM Role を一時的に引き受けます。

```text
GitHub Actions
  |
  | OIDC
  v
AWS IAM Role
```

この IAM Role には、必要最小限の権限だけを付与します。

---

## Phase 5: CodeDeploy でアプリを EC2 に配布する

GitHub Actions でテストとビルドが成功したら、アプリを zip にまとめて S3 にアップロードします。

その後、CodeDeploy にデプロイを依頼します。

```text
GitHub Actions
  |
  | upload zip
  v
S3
  |
  | create deployment
  v
CodeDeploy
  |
  | install / start / validate
  v
EC2
```

---

## Phase 6: ALB + Auto Scaling Group にする

EC2 1台に直接アクセスする構成から、ALB 経由の構成に変えます。

```text
Internet
  |
  v
ALB
  |
  v
Auto Scaling Group
  |
  v
EC2
```

これにより、以下を学びます。

```text
- ロードバランサ
- ヘルスチェック
- ターゲットグループ
- Auto Scaling Group
- EC2 の自動復旧
```

---

## Phase 7: Blue/Green デプロイを理解する

最後に、Blue/Green デプロイの考え方を学びます。

```text
Blue  = 現在本番として動いている環境
Green = 次バージョンを展開する新しい環境
```

流れは以下です。

```text
1. Blue 環境で v1 が動いている
2. Green 環境を用意する
3. Green 環境に v2 をデプロイする
4. Green の health check を確認する
5. 問題なければ ALB の通信を Green に切り替える
6. 問題があれば Blue に戻す
```

Blue/Green の目的は、単にデプロイをかっこよくすることではありません。

本質は、以下です。

```text
新バージョンが壊れていても、本番影響を小さくし、戻せる状態を維持すること
```

---

# 4. 前提条件

## 4-1. 必要なもの

このチュートリアルでは以下を使います。

```text
- AWS アカウント
- GitHub アカウント
- Terraform
- AWS CLI v2
- Git
- Go
- VS Code などのエディタ
```

確認コマンド:

```bash
terraform version
aws --version
git --version
go version
```

---

## 4-2. AWS 認証

ローカル PC から Terraform を実行する場合は、IAM Identity Center または一時認証情報を使う構成を推奨します。

学習用にどうしてもアクセスキーを使う場合も、以下は守ります。

```text
- root ユーザーのアクセスキーは作らない
- アクセスキーを GitHub にコミットしない
- .aws/credentials を公開しない
- 不要なアクセスキーは削除する
- MFA を設定する
```

---

## 4-3. 作業用ディレクトリ

作業ディレクトリを作成します。

```bash
mkdir terraform-aws-cicd-tutorial
cd terraform-aws-cicd-tutorial
```

最終的なディレクトリ構成は以下のようにします。

```text
terraform-aws-cicd-tutorial/
├── app/
│   ├── go.mod
│   ├── main.go
│   └── main_test.go
├── deploy/
│   ├── appspec.yml
│   └── scripts/
│       ├── install.sh
│       ├── start.sh
│       ├── stop.sh
│       └── validate.sh
├── infra/
│   ├── main.tf
│   ├── versions.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── network.tf
│   ├── security_group.tf
│   ├── iam.tf
│   ├── alb.tf
│   ├── asg.tf
│   ├── s3.tf
│   ├── codedeploy.tf
│   └── github_oidc.tf
└── .github/
    └── workflows/
        └── ci-cd.yml
```

---

# 5. サンプルアプリを作る

## 5-1. Go モジュールを作成

```bash
mkdir -p app
cd app
go mod init example.com/tutorial-app
```

---

## 5-2. `main.go`

```go
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
)

var version = "v1"

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "Hello from tutorial app %s\n", version)
	})

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "OK")
	})

	mux.HandleFunc("/version", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, version)
	})

	addr := ":" + port
	log.Printf("starting tutorial app on %s", addr)

	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}
```

---

## 5-3. `main_test.go`

```go
package main

import "testing"

func TestVersion(t *testing.T) {
	if version == "" {
		t.Fatal("version must not be empty")
	}
}
```

---

## 5-4. ローカルで実行

```bash
go test ./...
go run main.go
```

別ターミナルで確認します。

```bash
curl http://localhost:8080/
curl http://localhost:8080/health
curl http://localhost:8080/version
```

期待結果:

```text
Hello from tutorial app v1
OK
v1
```

---

# 6. CodeDeploy 用ファイルを作る

CodeDeploy は、`appspec.yml` を見て、EC2 上でどのスクリプトをどのタイミングで実行するか判断します。

## 6-1. `deploy/appspec.yml`

```yaml
version: 0.0
os: linux

files:
  - source: app
    destination: /opt/tutorial-app

hooks:
  BeforeInstall:
    - location: scripts/stop.sh
      timeout: 60
      runas: root

  AfterInstall:
    - location: scripts/install.sh
      timeout: 120
      runas: root

  ApplicationStart:
    - location: scripts/start.sh
      timeout: 60
      runas: root

  ValidateService:
    - location: scripts/validate.sh
      timeout: 60
      runas: root
```

---

## 6-2. `deploy/scripts/stop.sh`

```bash
#!/bin/bash
set -eux

systemctl stop tutorial-app || true
```

---

## 6-3. `deploy/scripts/install.sh`

```bash
#!/bin/bash
set -eux

useradd --system --no-create-home --shell /sbin/nologin tutorial-app || true

chmod +x /opt/tutorial-app/tutorial-app
chown -R tutorial-app:tutorial-app /opt/tutorial-app

cat > /etc/systemd/system/tutorial-app.service <<'UNIT'
[Unit]
Description=Tutorial App
After=network.target

[Service]
User=tutorial-app
Group=tutorial-app
WorkingDirectory=/opt/tutorial-app
ExecStart=/opt/tutorial-app/tutorial-app
Restart=always
RestartSec=3
Environment=PORT=8080

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable tutorial-app
```

---

## 6-4. `deploy/scripts/start.sh`

```bash
#!/bin/bash
set -eux

systemctl start tutorial-app
```

---

## 6-5. `deploy/scripts/validate.sh`

```bash
#!/bin/bash
set -eux

for i in $(seq 1 30); do
  if curl -fsS http://localhost:8080/health; then
    exit 0
  fi
  sleep 2
done

journalctl -u tutorial-app --no-pager -n 100 || true
exit 1
```

---

## 6-6. 実行権限を付ける

```bash
chmod +x deploy/scripts/*.sh
```

---

# 7. Terraform の考え方

## 7-1. Terraform で管理するもの

Terraform では、AWS の基盤を作ります。

```text
- ネットワーク
- セキュリティグループ
- ロードバランサ
- EC2 起動テンプレート
- Auto Scaling Group
- IAM Role
- S3 バケット
- CodeDeploy
- GitHub Actions OIDC
```

## 7-2. Terraform で管理しないもの

以下は、Terraform で毎回管理しません。

```text
- アプリの v1 / v2 のリリース操作
- zip の作成
- デプロイ実行履歴
- CodeDeploy の毎回の実行
```

ここを混ぜると、Terraform の state とアプリリリースの状態が絡みすぎます。

良い責務分担は以下です。

```text
Terraform:
  インフラの形を定義する

GitHub Actions:
  テスト、ビルド、成果物作成、デプロイ実行を行う

CodeDeploy:
  EC2 上でアプリを入れ替える
```

---

# 8. Terraform 構成

## 8-1. この章でやること

ここからは、AWS 上に CI/CD 用のインフラを作るための Terraform ファイルを作成します。

この章の作業は、すべて **ローカルPC** で行います。
AWS Console 上で手作業でリソースを作るのではなく、Terraform ファイルを書いて、後で `terraform apply` によって AWS 上に作成します。

## 作業場所

```text
ローカルPC
```

## 対象ディレクトリ

```text
terraform-aws-cicd-tutorial/infra/
```

## 作るファイル

```text
infra/
├── versions.tf
├── variables.tf
├── outputs.tf
├── network.tf
├── security_group.tf
├── s3.tf
├── alb.tf
├── asg.tf
├── iam.tf
├── codedeploy.tf
├── github_oidc.tf
└── terraform.tfvars
```

## この章で作るAWSリソース

```text
VPC
Subnet
Internet Gateway
Route Table
Security Group
S3 Artifact Bucket
ALB
Target Group
Launch Template
Auto Scaling Group
IAM Role
CodeDeploy Application
CodeDeploy Deployment Group
GitHub Actions 用 OIDC Role
```

## 重要な考え方

この章では、**アプリをデプロイするのではなく、アプリをデプロイできる土台を作ります。**

```text
terraform apply:
  AWS上のインフラを作る

git push:
  GitHub Actionsを起動し、アプリをデプロイする
```

この2つを混同しないようにします。

---

## 8-2. `versions.tf` を作る

## 作業場所

```text
ローカルPC
```

## 対象ファイル

```text
infra/versions.tf
```

## 目的

Terraform 本体のバージョンと、AWS Provider のバージョンを指定します。

```hcl
terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
```

---

## 8-3. `variables.tf` を作る

## 作業場所

```text
ローカルPC
```

## 対象ファイル

```text
infra/variables.tf
```

## 目的

リージョン名、プロジェクト名、GitHub リポジトリ情報などを変数化します。

```hcl
variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "project" {
  description = "Project name"
  type        = string
  default     = "terraform-aws-cicd-tutorial"
}

variable "github_owner" {
  description = "GitHub owner or organization name"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
}
```

---

## 8-4. `terraform.tfvars` を作る

## 作業場所

```text
ローカルPC
```

## 対象ファイル

```text
infra/terraform.tfvars
```

## 目的

自分の GitHub リポジトリ情報を Terraform に渡します。

```hcl
github_owner = "your-github-user-or-org"
github_repo  = "terraform-aws-cicd-tutorial"
```

例:

```hcl
github_owner = "example-user"
github_repo  = "terraform-aws-cicd-tutorial"
```

`github_owner` は GitHub のユーザー名または Organization 名です。
`github_repo` は GitHub リポジトリ名です。

この値は、後で GitHub Actions OIDC の信頼条件に使います。

つまり、AWS 側では次のように制限します。

```text
このGitHubリポジトリの main ブランチから来た GitHub Actions だけ、
AWSのIAM Roleを引き受けてよい
```

---

## 8-5. `outputs.tf` を作る

## 作業場所

```text
ローカルPC
```

## 対象ファイル

```text
infra/outputs.tf
```

## 目的

Terraform 実行後に、GitHub Actions の設定や動作確認で使う値を表示します。

```hcl
output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.app.dns_name
}

output "artifact_bucket" {
  description = "S3 bucket for deployment artifacts"
  value       = aws_s3_bucket.artifact.bucket
}

output "codedeploy_app_name" {
  description = "CodeDeploy application name"
  value       = aws_codedeploy_app.app.name
}

output "codedeploy_deployment_group_name" {
  description = "CodeDeploy deployment group name"
  value       = aws_codedeploy_deployment_group.app.deployment_group_name
}

output "github_actions_role_arn" {
  description = "IAM Role ARN for GitHub Actions"
  value       = aws_iam_role.github_actions.arn
}
```

これらの値は、後で GitHub Actions の Variables に登録します。

---

## 8-6. `network.tf` を作る

## 作業場所

```text
ローカルPC
```

## 対象ファイル

```text
infra/network.tf
```

## 目的

このファイルでは、AWS 上の基本ネットワークを作ります。

作るものは以下です。

```text
VPC
Public Subnet x 2
Internet Gateway
Route Table
Route Table Association
```

オンプレでいうと、以下をコードで作るイメージです。

```text
社内ネットワーク
ネットワークセグメント
インターネット出口
ルーティング設定
```

このチュートリアルでは、学習しやすさを優先して Public Subnet を2つ作ります。

```text
VPC
├── Public Subnet A
└── Public Subnet C
```

本番では EC2 を Private Subnet に置くことが多いですが、最初から NAT Gateway や VPC Endpoint まで入れると複雑になるため、今回は以下の方針にします。

```text
EC2 は Public Subnet に置く
ただし SSH は開けない
EC2 へのアプリ通信は ALB からのみ許可する
```

---

## `infra/network.tf`

```hcl
locals {
  name_prefix = var.project

  common_tags = {
    Project   = var.project
    ManagedBy = "Terraform"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 1)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-${count.index + 1}"
  })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-igw"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-rt"
  })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
```

---

## このファイルで重要な点

`aws_subnet.public` は `count = 2` で2つ作っています。

```hcl
count = 2
```

CIDR は `cidrsubnet` で分割しています。

```hcl
cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 1)
```

結果として、おおよそ以下のようなサブネットになります。

```text
10.0.1.0/24
10.0.2.0/24
```

Availability Zone も2つ使います。

```hcl
availability_zone = data.aws_availability_zones.available.names[count.index]
```

これにより、後で ALB や Auto Scaling Group を複数 AZ にまたがって配置できます。

---

# 8-7. `security_group.tf` を作る

## 作業場所

```text
ローカルPC
```

## 対象ファイル

```text
infra/security_group.tf
```

## 目的

このファイルでは、ALB 用と EC2 用の Security Group を作ります。

作る Security Group は2つです。

```text
ALB Security Group
EC2 App Security Group
```

通信の流れは以下です。

```text
Internet
  ↓ TCP 80
ALB
  ↓ TCP 8080
EC2
```

このチュートリアルでは SSH は開けません。

```text
開けない:
  TCP 22 from 0.0.0.0/0
```

EC2 にログインしたい場合は、後続で SSM Session Manager を使います。

---

## `infra/security_group.tf`

```hcl
resource "aws_security_group" "alb" {
  name_prefix = "${local.name_prefix}-alb-"
  description = "Security group for ALB"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-alb-sg"
  })
}

resource "aws_security_group" "app" {
  name_prefix = "${local.name_prefix}-app-"
  description = "Security group for application EC2 instances"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-app-sg"
  })
}

# Internet -> ALB : HTTP
resource "aws_vpc_security_group_ingress_rule" "alb_http_ipv4" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTP from the internet"

  ip_protocol = "tcp"
  from_port   = 80
  to_port     = 80
  cidr_ipv4   = "0.0.0.0/0"
}

# ALB -> Internet : outbound
resource "aws_vpc_security_group_egress_rule" "alb_all_outbound_ipv4" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow all outbound traffic from ALB"

  ip_protocol = "-1"
  cidr_ipv4   = "0.0.0.0/0"
}

# ALB -> EC2 : application port
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id = aws_security_group.app.id
  description       = "Allow application traffic from ALB"

  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.alb.id
}

# EC2 -> Internet : outbound
resource "aws_vpc_security_group_egress_rule" "app_all_outbound_ipv4" {
  security_group_id = aws_security_group.app.id
  description       = "Allow all outbound traffic from application instances"

  ip_protocol = "-1"
  cidr_ipv4   = "0.0.0.0/0"
}
```

---

## このファイルで重要な点

EC2 側の Security Group は、インターネット全体からのアクセスを許可していません。

許可しているのは、ALB の Security Group から来た TCP 8080 だけです。

```hcl
referenced_security_group_id = aws_security_group.alb.id
```

つまり、EC2 が Public Subnet にあっても、アプリには ALB 経由でしか入れない構成にしています。

オンプレでいうと、以下に近いです。

```text
外部公開:
  ロードバランサだけ

アプリサーバー:
  ロードバランサからの通信だけ許可
```

---

# 8-8. `s3.tf` を作る

## 作業場所

```text
ローカルPC
```

## 対象ファイル

```text
infra/s3.tf
```

## 目的

このファイルでは、GitHub Actions が作成したアプリの zip ファイルを保存する S3 バケットを作ります。

この S3 バケットは、デプロイ成果物置き場です。

```text
GitHub Actions
  ↓
revision.zip
  ↓
S3 Artifact Bucket
  ↓
CodeDeploy
  ↓
EC2
```

成果物は、後で GitHub Actions によって以下のようなパスに保存されます。

```text
revisions/<commit-sha>.zip
```

---

## `infra/s3.tf`

```hcl
resource "aws_s3_bucket" "artifact" {
  bucket_prefix = "${local.name_prefix}-artifact-"

  # チュートリアルでは destroy しやすいように true にする。
  # 実務では誤削除防止のため、要件に応じて false も検討する。
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-artifact"
  })
}

resource "aws_s3_bucket_public_access_block" "artifact" {
  bucket = aws_s3_bucket.artifact.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "artifact" {
  bucket = aws_s3_bucket.artifact.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifact" {
  bucket = aws_s3_bucket.artifact.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
```

---

## このファイルで重要な点

`bucket_prefix` を使っているため、S3 バケット名は Terraform 実行時に一意な名前で作られます。

```hcl
bucket_prefix = "${local.name_prefix}-artifact-"
```

S3 バケット名は全世界で一意である必要があるため、固定名にすると他の人と衝突する可能性があります。

チュートリアルでは、削除しやすくするために `force_destroy = true` にしています。

```hcl
force_destroy = true
```

これは、バケット内に zip ファイルが残っていても `terraform destroy` で削除しやすくするためです。

ただし、実務では誤削除防止のため、安易に `true` にしない方がよい場合があります。

---

# 8-9. `alb.tf` を作る

## 作業場所

```text
ローカルPC
```

## 対象ファイル

```text
infra/alb.tf
```

## 目的

このファイルでは、Application Load Balancer を作ります。

作るものは以下です。

```text
ALB
Target Group
Listener
```

通信の流れは以下です。

```text
Internet
  ↓ HTTP 80
ALB
  ↓ HTTP 8080
Target Group
  ↓
EC2
```

---

## `infra/alb.tf`

```hcl
resource "aws_lb" "app" {
  name               = substr("${local.name_prefix}-alb", 0, 32)
  internal           = false
  load_balancer_type = "application"

  security_groups = [
    aws_security_group.alb.id
  ]

  subnets = aws_subnet.public[*].id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-alb"
  })
}

resource "aws_lb_target_group" "app" {
  name = substr("${local.name_prefix}-tg", 0, 32)

  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  protocol = "HTTP"
  port     = 8080

  deregistration_delay = 30

  health_check {
    enabled             = true
    protocol            = "HTTP"
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-tg"
  })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn

  protocol = "HTTP"
  port     = 80

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-http-listener"
  })
}
```

---

## このファイルで重要な点

ALB はインターネットから HTTP 80 番でアクセスを受けます。

```hcl
port     = 80
protocol = "HTTP"
```

一方、EC2 上の Go アプリは 8080 番で待ち受けます。

```hcl
port = 8080
```

ALB の health check は `/health` を見ます。

```hcl
path    = "/health"
matcher = "200"
```

つまり、アプリが次を返せば正常です。

```text
GET /health -> HTTP 200
```

この `/health` は、CodeDeploy の `validate.sh` でも使います。

```text
ALB:
  外から見て正常か確認する

CodeDeploy:
  デプロイ後にEC2上で正常か確認する
```

---

# 8-10. `asg.tf` を作る

## 作業場所

```text
ローカルPC
```

## 対象ファイル

```text
infra/asg.tf
```

## 目的

このファイルでは、EC2 を直接作るのではなく、Launch Template と Auto Scaling Group を作ります。

作るものは以下です。

```text
Amazon Linux 2023 AMI の参照
Launch Template
Auto Scaling Group
```

オンプレでいうと、以下に近いです。

```text
サーバー構築手順書
  +
必要台数を維持する仕組み
```

EC2 を1台だけ手作業で作るのではなく、Auto Scaling Group に管理させるのがポイントです。

---

## 重要な注意

この `asg.tf` は、後続の第9章で作る IAM Role を参照します。

具体的には、以下です。

```hcl
aws_iam_instance_profile.ec2.name
```

そのため、8章を書いた直後に `terraform validate` や `terraform plan` を実行すると、まだ第9章の IAM ファイルがないため失敗します。

この時点では、まずファイルを作るだけです。

実行タイミングは以下です。

```text
8章:
  Terraformファイルを作る

9章:
  IAMファイルを作る

11章以降:
  GitHub Actions設定まで終わったら terraform plan / apply する
```

---

## `infra/asg.tf`

```hcl
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_launch_template" "app" {
  name_prefix = "${local.name_prefix}-lt-"

  image_id      = data.aws_ssm_parameter.al2023_ami.value
  instance_type = "t3.micro"

  vpc_security_group_ids = [
    aws_security_group.app.id
  ]

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2.name
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  credit_specification {
    cpu_credits = "standard"
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 8
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -eux

    dnf update -y
    dnf install -y ruby wget curl

    cd /tmp

    wget https://aws-codedeploy-${var.aws_region}.s3.${var.aws_region}.amazonaws.com/latest/install
    chmod +x ./install
    ./install auto

    systemctl enable --now codedeploy-agent
    systemctl status codedeploy-agent --no-pager || true
  EOF
  )

  tag_specifications {
    resource_type = "instance"

    tags = merge(local.common_tags, {
      Name = "${local.name_prefix}-app"
    })
  }

  tag_specifications {
    resource_type = "volume"

    tags = merge(local.common_tags, {
      Name = "${local.name_prefix}-app-volume"
    })
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-lt"
  })
}

resource "aws_autoscaling_group" "app" {
  name_prefix = "${local.name_prefix}-asg-"

  vpc_zone_identifier = aws_subnet.public[*].id

  desired_capacity = 1
  min_size         = 1
  max_size         = 2

  health_check_type         = "ELB"
  health_check_grace_period = 300

  target_group_arns = [
    aws_lb_target_group.app.arn
  ]

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-app"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = var.project
    propagate_at_launch = true
  }

  tag {
    key                 = "ManagedBy"
    value               = "Terraform"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}
```

---

## このファイルで重要な点

EC2 の AMI は、AMI ID を直接固定せず、SSM Parameter Store から Amazon Linux 2023 の最新 AMI を取得します。

```hcl
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
```

EC2 には、Security Group と IAM Instance Profile を付けます。

```hcl
vpc_security_group_ids = [
  aws_security_group.app.id
]

iam_instance_profile {
  name = aws_iam_instance_profile.ec2.name
}
```

`user_data` では、CodeDeploy Agent をインストールします。

```bash
wget https://aws-codedeploy-${var.aws_region}.s3.${var.aws_region}.amazonaws.com/latest/install
chmod +x ./install
./install auto
```

このスクリプトは、ローカルPCで実行するものではありません。

```text
ローカルPC:
  asg.tf に user_data として書く

AWS:
  EC2 起動時に cloud-init 経由で自動実行される
```

Auto Scaling Group は、ALB の Target Group に紐づけます。

```hcl
target_group_arns = [
  aws_lb_target_group.app.arn
]
```

これにより、ASG で起動した EC2 が ALB の振り分け先になります。

---

# 8章終了時点の確認

8章終了時点で、以下のファイルができています。

```text
infra/
├── versions.tf
├── variables.tf
├── outputs.tf
├── network.tf
├── security_group.tf
├── s3.tf
├── alb.tf
└── asg.tf
```

ただし、この時点ではまだ `terraform plan` は実行しません。

理由は、`asg.tf` が第9章で作る IAM リソースを参照しているためです。

```text
まだ存在しない参照:
  aws_iam_instance_profile.ec2
```

次の第9章で、以下を作ります。

```text
infra/iam.tf
infra/github_oidc.tf
```

第9章まで完了すると、`asg.tf` の IAM 参照が解決されます。


# 9. IAM 設計

## 9-1. この章でやること

この章では、AWS の権限管理である IAM を Terraform で定義します。

この章も、作業はすべて **ローカルPC** で行います。
AWS Console で IAM Role を手作業作成するのではなく、Terraform ファイルとして作成します。

## 作業場所

```text id="0tdt52"
ローカルPC
```

## 対象ディレクトリ

```text id="wvud03"
terraform-aws-cicd-tutorial/infra/
```

## 作るファイル

```text id="2xciuy"
infra/iam.tf
infra/github_oidc.tf
```

## この章で作る IAM リソース

```text id="lo56sc"
EC2 Instance Role
EC2 Instance Profile
EC2用 S3 Artifact 読み取りポリシー
CodeDeploy Service Role
GitHub Actions OIDC Provider
GitHub Actions Role
GitHub Actions用 S3 / CodeDeploy 操作ポリシー
```

## なぜ IAM が必要か

今回の構成では、複数のサービスが AWS リソースを操作します。

```text id="ogmzau"
EC2:
  SSM Session Manager を使う
  CodeDeploy Agent として動く
  S3 からデプロイ成果物を取得する

CodeDeploy:
  EC2 / Auto Scaling Group / ALB と連携してデプロイする

GitHub Actions:
  S3 に revision.zip をアップロードする
  CodeDeploy の deployment を作成する
```

そのため、それぞれに適切な IAM Role を付けます。

---

# 9-2. IAM の全体像

この章で作る Role は3種類です。

```text id="oxue34"
1. EC2 Instance Role
2. CodeDeploy Service Role
3. GitHub Actions Role
```

それぞれの役割は以下です。

```text id="wx7yg0"
EC2 Instance Role:
  EC2自身が使う権限。
  SSMやS3 artifact取得に使う。

CodeDeploy Service Role:
  CodeDeployサービス自身が使う権限。
  EC2 / ASG / ALB などを扱うために使う。

GitHub Actions Role:
  GitHub Actions が OIDC 経由で引き受ける権限。
  S3 upload と CodeDeploy 実行に使う。
```

図で表すと以下です。

```text id="c2vfcx"
GitHub Actions
  ↓ OIDC
GitHub Actions Role
  ↓
S3 / CodeDeploy


CodeDeploy
  ↓ assume role
CodeDeploy Service Role
  ↓
EC2 / ASG / ALB


EC2
  ↓ instance profile
EC2 Instance Role
  ↓
SSM / S3
```

---

# 9-3. `iam.tf` を作る

## 作業場所

```text id="zsxavl"
ローカルPC
```

## 対象ファイル

```text id="gjtl8z"
infra/iam.tf
```

## 目的

`iam.tf` では、以下を作ります。

```text id="l5rldc"
EC2 Instance Role
EC2 Instance Profile
EC2用 SSM 権限
EC2用 S3 Artifact 読み取り権限
CodeDeploy Service Role
CodeDeploy用 AWS 管理ポリシー attachment
```

---

## `infra/iam.tf`

```hcl id="dsk1hp"
# ============================================================
# EC2 Instance Role
# ============================================================

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    sid    = "AllowEC2AssumeRole"
    effect = "Allow"

    actions = [
      "sts:AssumeRole"
    ]

    principals {
      type = "Service"
      identifiers = [
        "ec2.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name_prefix        = "${local.name_prefix}-ec2-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ec2-role"
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name_prefix = "${local.name_prefix}-ec2-"
  role        = aws_iam_role.ec2.name

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ec2-instance-profile"
  })
}

# SSM Session Manager を使うためのAWS管理ポリシー
resource "aws_iam_role_policy_attachment" "ec2_ssm_managed_instance_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# EC2上のCodeDeploy AgentがS3 artifact bucketから成果物を取得するためのポリシー
data "aws_iam_policy_document" "ec2_artifact_read" {
  statement {
    sid    = "AllowGetBucketLocation"
    effect = "Allow"

    actions = [
      "s3:GetBucketLocation"
    ]

    resources = [
      aws_s3_bucket.artifact.arn
    ]
  }

  statement {
    sid    = "AllowListArtifactBucket"
    effect = "Allow"

    actions = [
      "s3:ListBucket"
    ]

    resources = [
      aws_s3_bucket.artifact.arn
    ]
  }

  statement {
    sid    = "AllowReadArtifactObjects"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion"
    ]

    resources = [
      "${aws_s3_bucket.artifact.arn}/*"
    ]
  }
}

resource "aws_iam_policy" "ec2_artifact_read" {
  name_prefix = "${local.name_prefix}-ec2-artifact-read-"
  description = "Allow EC2 instances to read CodeDeploy artifacts from S3"
  policy      = data.aws_iam_policy_document.ec2_artifact_read.json

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ec2-artifact-read"
  })
}

resource "aws_iam_role_policy_attachment" "ec2_artifact_read" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.ec2_artifact_read.arn
}


# ============================================================
# CodeDeploy Service Role
# ============================================================

data "aws_iam_policy_document" "codedeploy_assume_role" {
  statement {
    sid    = "AllowCodeDeployAssumeRole"
    effect = "Allow"

    actions = [
      "sts:AssumeRole"
    ]

    principals {
      type = "Service"
      identifiers = [
        "codedeploy.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_role" "codedeploy" {
  name_prefix        = "${local.name_prefix}-codedeploy-"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_assume_role.json

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-codedeploy-role"
  })
}

# EC2/オンプレミス向けCodeDeployで使うAWS管理ポリシー
resource "aws_iam_role_policy_attachment" "codedeploy_service_role" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
}
```

---

# 9-4. `iam.tf` の解説

## EC2 Instance Role

EC2 Instance Role は、EC2 インスタンス自身に付与する Role です。

```hcl id="8i41i7"
resource "aws_iam_role" "ec2" {
  name_prefix        = "${local.name_prefix}-ec2-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}
```

この Role を EC2 に直接付けるのではなく、Instance Profile 経由で付けます。

```hcl id="0qn6v0"
resource "aws_iam_instance_profile" "ec2" {
  name_prefix = "${local.name_prefix}-ec2-"
  role        = aws_iam_role.ec2.name
}
```

第8章の `asg.tf` では、Launch Template からこの Instance Profile を参照しています。

```hcl id="3uyy30"
iam_instance_profile {
  name = aws_iam_instance_profile.ec2.name
}
```

つまり、つながりは以下です。

```text id="el2q88"
aws_iam_role.ec2
  ↓
aws_iam_instance_profile.ec2
  ↓
aws_launch_template.app
  ↓
EC2
```

---

## SSM Session Manager 用権限

EC2 に SSH で入る代わりに、SSM Session Manager を使えるようにします。

そのために、EC2 Role に `AmazonSSMManagedInstanceCore` を付けます。

```hcl id="u8nbly"
resource "aws_iam_role_policy_attachment" "ec2_ssm_managed_instance_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
```

この教材では、Security Group で SSH 22番を開けません。

```text id="zozlwp"
開けない:
  TCP 22 from 0.0.0.0/0
```

必要な場合は、Session Manager で接続します。

---

## S3 Artifact 読み取り権限

GitHub Actions は、アプリのビルド成果物を S3 にアップロードします。

```text id="agsymt"
GitHub Actions
  ↓
S3 Artifact Bucket
```

その後、CodeDeploy Agent が EC2 上で artifact を取得します。

```text id="cu8adl"
EC2上のCodeDeploy Agent
  ↓
S3 Artifact Bucket から revision.zip を取得
```

そのため、EC2 Role には S3 から成果物を読む権限が必要です。

```hcl id="k49ymv"
actions = [
  "s3:GetObject",
  "s3:GetObjectVersion"
]
```

対象は、チュートリアル用の artifact bucket のみに絞っています。

```hcl id="s31bu5"
resources = [
  "${aws_s3_bucket.artifact.arn}/*"
]
```

---

## CodeDeploy Service Role

CodeDeploy Service Role は、CodeDeploy サービス自身が AWS リソースを操作するために使います。

```hcl id="o6g6gb"
resource "aws_iam_role" "codedeploy" {
  name_prefix        = "${local.name_prefix}-codedeploy-"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_assume_role.json
}
```

CodeDeploy は、この Role を使って EC2 や Auto Scaling Group と連携します。

```text id="neknf8"
CodeDeploy
  ↓ assume role
CodeDeploy Service Role
  ↓
EC2 / ASG / ALB
```

この Role には、AWS 管理ポリシー `AWSCodeDeployRole` を付けます。

```hcl id="k5v04j"
policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
```

---

# 9-5. `github_oidc.tf` を作る

## 作業場所

```text id="a4yfst"
ローカルPC
```

## 対象ファイル

```text id="zp5p40"
infra/github_oidc.tf
```

## 目的

`github_oidc.tf` では、GitHub Actions から AWS を操作するための Role を作ります。

この教材では、GitHub Secrets に AWS の長期アクセスキーを保存しません。

使わないもの:

```text id="4b3fwg"
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

代わりに、GitHub Actions OIDC を使います。

```text id="hg5xwn"
GitHub Actions
  ↓ OIDC
AWS IAM Role
  ↓
S3 upload / CodeDeploy create-deployment
```

---

## `infra/github_oidc.tf`

```hcl id="y5lkhw"
# ============================================================
# GitHub Actions OIDC Provider
# ============================================================

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-github-oidc"
  })
}


# ============================================================
# GitHub Actions Role
# ============================================================

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    sid    = "AllowGitHubActionsAssumeRole"
    effect = "Allow"

    actions = [
      "sts:AssumeRoleWithWebIdentity"
    ]

    principals {
      type = "Federated"
      identifiers = [
        aws_iam_openid_connect_provider.github.arn
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"

      values = [
        "sts.amazonaws.com"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"

      values = [
        "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/main"
      ]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name_prefix        = "${local.name_prefix}-gha-"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-github-actions-role"
  })
}


# ============================================================
# GitHub Actions Permissions
# ============================================================

data "aws_iam_policy_document" "github_actions_deploy" {
  statement {
    sid    = "AllowReadArtifactBucketMetadata"
    effect = "Allow"

    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket"
    ]

    resources = [
      aws_s3_bucket.artifact.arn
    ]
  }

  statement {
    sid    = "AllowUploadDeploymentArtifacts"
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:AbortMultipartUpload"
    ]

    resources = [
      "${aws_s3_bucket.artifact.arn}/revisions/*"
    ]
  }

  statement {
    sid    = "AllowCreateAndCheckCodeDeployDeployment"
    effect = "Allow"

    actions = [
      "codedeploy:CreateDeployment",
      "codedeploy:GetDeployment",
      "codedeploy:GetDeploymentConfig",
      "codedeploy:GetApplication",
      "codedeploy:GetDeploymentGroup",
      "codedeploy:ListDeployments"
    ]

    resources = [
      "*"
    ]
  }
}

resource "aws_iam_policy" "github_actions_deploy" {
  name_prefix = "${local.name_prefix}-gha-deploy-"
  description = "Allow GitHub Actions to upload artifacts and create CodeDeploy deployments"
  policy      = data.aws_iam_policy_document.github_actions_deploy.json

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-github-actions-deploy"
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_deploy" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions_deploy.arn
}
```

---

# 9-6. `github_oidc.tf` の解説

## OIDC Provider

まず、AWS 側に GitHub Actions の OIDC Provider を登録します。

```hcl id="3zpukd"
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]
}
```

これは、AWS に対して以下を教える設定です。

```text id="zrw794"
GitHub Actions から発行された OIDC Token を信頼候補として扱う
```

ただし、OIDC Provider を作っただけでは、どのリポジトリからでも AWS を操作できるわけではありません。

次の Trust Policy で、対象リポジトリとブランチを制限します。

---

## GitHub Actions Role の Trust Policy

GitHub Actions Role の信頼ポリシーでは、次の2つを確認します。

```text id="wy5xi1"
aud:
  sts.amazonaws.com であること

sub:
  指定した GitHub リポジトリの main ブランチであること
```

該当箇所は以下です。

```hcl id="xa6sal"
condition {
  test     = "StringEquals"
  variable = "token.actions.githubusercontent.com:aud"

  values = [
    "sts.amazonaws.com"
  ]
}
```

```hcl id="pg8sp9"
condition {
  test     = "StringEquals"
  variable = "token.actions.githubusercontent.com:sub"

  values = [
    "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/main"
  ]
}
```

つまり、この Role を引き受けられるのは以下だけです。

```text id="vh1i3d"
GitHub owner:
  var.github_owner

GitHub repo:
  var.github_repo

branch:
  main
```

例:

```text id="qbqv8r"
repo:example-user/terraform-aws-cicd-tutorial:ref:refs/heads/main
```

---

## GitHub Actions に許可するS3操作

GitHub Actions は、ビルドした `revision.zip` を S3 にアップロードします。

そのため、以下の権限を付けます。

```hcl id="v3jd92"
actions = [
  "s3:PutObject",
  "s3:AbortMultipartUpload"
]
```

アップロード先は、artifact bucket の `revisions/` 配下だけに絞ります。

```hcl id="d7u5a6"
resources = [
  "${aws_s3_bucket.artifact.arn}/revisions/*"
]
```

GitHub Actions からアップロードするパスは、後続の workflow で以下のようにします。

```text id="acycru"
revisions/<commit-sha>.zip
```

---

## GitHub Actions に許可する CodeDeploy 操作

GitHub Actions は、S3 に zip を置いたあと、CodeDeploy deployment を作成します。

そのため、以下の権限を付けます。

```hcl id="4zbh2g"
actions = [
  "codedeploy:CreateDeployment",
  "codedeploy:GetDeployment",
  "codedeploy:GetDeploymentConfig",
  "codedeploy:GetApplication",
  "codedeploy:GetDeploymentGroup",
  "codedeploy:ListDeployments"
]
```

この教材では、CodeDeploy 操作の `resources` は `*` にしています。

```hcl id="15wq3y"
resources = [
  "*"
]
```

理由は、CodeDeploy の一部操作や `deploymentId` を使う確認処理では、リソース単位の制限がやや複雑になるためです。

実務では、対象の Application / Deployment Group に絞ることを検討します。

---

# 9-7. 既存の GitHub OIDC Provider がある場合

AWS アカウント内に、すでに GitHub Actions 用の OIDC Provider が存在する場合があります。

その場合、Terraform apply 時に以下のようなエラーになる可能性があります。

```text id="wv83c7"
EntityAlreadyExists:
Provider with url https://token.actions.githubusercontent.com already exists.
```

学習用の新規アカウントでは、そのまま作成して問題ありません。

既存アカウントでこのエラーが出た場合は、次のどちらかで対応します。

```text id="p81e1m"
対応1:
  既存の OIDC Provider を terraform import する

対応2:
  data source で既存の OIDC Provider を参照する
```

初心者向けチュートリアルでは、まず新規アカウントまたは学習用アカウントで進める方が分かりやすいです。

---

# 9-8. 第9章終了時点の確認

第9章終了時点で、以下のファイルが追加されています。

```text id="n2mjcl"
infra/
├── iam.tf
└── github_oidc.tf
```

第8章までのファイルと合わせると、ここまでで以下ができています。

```text id="z8yrqy"
infra/
├── versions.tf
├── variables.tf
├── outputs.tf
├── network.tf
├── security_group.tf
├── s3.tf
├── alb.tf
├── asg.tf
├── iam.tf
└── github_oidc.tf
```

第8章で `asg.tf` が参照していた以下のリソースは、この章で定義されました。

```hcl id="z4xjfh"
aws_iam_instance_profile.ec2
```

そのため、`asg.tf` の以下の参照は解決されます。

```hcl id="ic82z3"
iam_instance_profile {
  name = aws_iam_instance_profile.ec2.name
}
```

---

# 9-9. まだ `terraform plan` しない理由

第9章までで IAM 周りはかなり揃いました。

ただし、まだ `terraform plan` や `terraform validate` は実行しません。

理由は、前の章で作った `outputs.tf` が、まだ作成していない CodeDeploy リソースを参照しているためです。

まだ存在しない参照:

```text id="v87sot"
aws_codedeploy_app.app
aws_codedeploy_deployment_group.app
```

これらは後続の `codedeploy.tf` で作ります。

つまり、現時点では以下の状態です。

```text id="59r3vj"
作成済み:
  network.tf
  security_group.tf
  s3.tf
  alb.tf
  asg.tf
  iam.tf
  github_oidc.tf

まだ必要:
  codedeploy.tf の具体実装
```

`terraform plan` を実行するのは、`codedeploy.tf` まで完成してからです。

---

# 9-10. 第9章で理解すべきこと

この章のポイントは、以下です。

```text id="peyw2c"
EC2にはアクセスキーを置かない。
EC2にはIAM Instance Profileを付ける。

GitHub SecretsにAWSアクセスキーを置かない。
GitHub ActionsはOIDCでIAM Roleを引き受ける。

CodeDeployにはService Roleが必要。
CodeDeployはそのRoleでEC2 / ASG / ALBと連携する。

S3 artifact bucketへのアクセス権限は、
EC2用とGitHub Actions用で分ける。
```

特に重要なのは、以下の分離です。

```text id="pnyf36"
EC2 Role:
  S3からartifactを読む

GitHub Actions Role:
  S3へartifactを書く
  CodeDeployを起動する

CodeDeploy Role:
  デプロイ対象のEC2 / ASG / ALBと連携する
```

この分離ができていると、後続の GitHub Actions と CodeDeploy の流れが理解しやすくなります。


# 10. EC2 起動時に入れるもの

## 10-1. この章でやること

この章では、EC2 起動時に自動実行される `user_data` の内容を定義します。

## 作業場所

```text
ローカルPC
```

## 対象ファイル

```text
infra/asg.tf
```

## 実際に処理が走る場所

```text
AWS上のEC2
```

つまり、作業者が EC2 にログインして手作業するのではありません。
ローカルPCで Terraform に `user_data` を書き、EC2 起動時に AWS 側で自動実行されます。

---

## 10-2. user_data でやること

EC2 起動時に、以下を行います。

```text
OSパッケージ更新
必要パッケージのインストール
CodeDeploy Agent のインストール
CodeDeploy Agent の起動
SSM Agent の起動確認
```

Amazon Linux 2023 では、パッケージ管理に `dnf` を使います。

例:

```bash
#!/bin/bash
set -eux

dnf update -y
dnf install -y ruby wget curl

cd /tmp
wget https://aws-codedeploy-ap-northeast-1.s3.ap-northeast-1.amazonaws.com/latest/install
chmod +x ./install
./install auto

systemctl enable --now codedeploy-agent
systemctl status codedeploy-agent --no-pager
```

このスクリプトは、ローカルPCで直接実行するものではありません。

```text
ローカルPC:
  asg.tf に user_data として書く

AWS:
  EC2 起動時に cloud-init 経由で実行される
```

---

# 10. EC2 起動時に入れるもの

## 10-0. 先に `codedeploy.tf` を作る

## 10-0-1. この節でやること

第8章で ALB / Target Group / Auto Scaling Group を作りました。
第9章で EC2 Role / CodeDeploy Service Role / GitHub Actions Role を作りました。

しかし、まだ CodeDeploy 本体のリソースがありません。

このままだと、以下が存在しません。

```text id="bvhm6z"
aws_codedeploy_app.app
aws_codedeploy_deployment_group.app
```

そのため、`outputs.tf` の以下の参照も解決できません。

```hcl id="ibsey6"
aws_codedeploy_app.app.name
aws_codedeploy_deployment_group.app.deployment_group_name
```

この節では、先に `infra/codedeploy.tf` を作成します。

---

## 作業場所

```text id="xchot2"
ローカルPC
```

## 対象ディレクトリ

```text id="4gikkx"
terraform-aws-cicd-tutorial/infra/
```

## 作るファイル

```text id="yxmbf0"
infra/codedeploy.tf
```

## この節で作るAWSリソース

```text id="vrzx5l"
CodeDeploy Application
CodeDeploy Deployment Group
```

---

## 10-0-2. 今回はまず in-place deployment にする

この教材では、最初から Blue/Green にせず、まず **in-place deployment** で v1 → v2 の CI/CD を体験します。

```text id="tfm6tr"
in-place deployment:
  既存のEC2上でアプリを入れ替える

Blue/Green deployment:
  新しい環境にアプリを入れて、あとからトラフィックを切り替える
```

理由は、いきなり Blue/Green まで入れると、以下が同時に出てきて初心者には重くなるためです。

```text id="4yibd5"
Green環境
Auto Scaling Groupのコピー
Target Group切り替え
Traffic shifting
Rollback設定
Terraform stateとの境界
```

この章では、まず次を成立させます。

```text id="zbonfq"
GitHub Actions
  ↓
S3
  ↓
CodeDeploy
  ↓
Auto Scaling Group配下のEC2
  ↓
ALB経由で確認
```

Blue/Green は後続章で扱います。

---

## 10-0-3. 重要: ASG の health check 設定を一部修正する

第8章の `asg.tf` では、以下のようにしていた場合があります。

```hcl id="thetlw"
health_check_type = "ELB"
```

しかし、この教材の初回デプロイでは、Terraform apply 直後の EC2 にはまだアプリが入っていません。

つまり、初回デプロイ前は以下の状態です。

```text id="aq5ceq"
EC2は起動している
CodeDeploy Agentは入っている
でも tutorial-app はまだ動いていない
/health もまだ返せない
```

この状態で ASG の health check を `ELB` にすると、ALB の `/health` が失敗し、初回デプロイ前に EC2 が不健康扱いになる可能性があります。

そのため、この in-place 学習フェーズでは、`infra/asg.tf` の ASG を以下のようにします。

```hcl id="pod31s"
health_check_type         = "EC2"
health_check_grace_period = 300
```

`aws_autoscaling_group.app` の該当箇所を確認し、必要なら修正してください。

```hcl id="hwrzz8"
resource "aws_autoscaling_group" "app" {
  name_prefix = "${local.name_prefix}-asg-"

  vpc_zone_identifier = aws_subnet.public[*].id

  desired_capacity = 1
  min_size         = 1
  max_size         = 2

  # 初回デプロイ前はアプリがまだ入っていないため、ここではEC2ヘルスチェックにする
  health_check_type         = "EC2"
  health_check_grace_period = 300

  target_group_arns = [
    aws_lb_target_group.app.arn
  ]

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-app"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = var.project
    propagate_at_launch = true
  }

  tag {
    key                 = "ManagedBy"
    value               = "Terraform"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}
```

ALB 自体の `/health` ヘルスチェックは残します。

```text id="v2v16g"
ALB:
  /health でアプリ正常性を見る

ASG:
  この段階ではEC2自体の生存を見て台数維持する
```

後続の発展課題では、AMIにアプリを焼き込む、または起動直後にアプリを配置する方式にして、ASG側も `ELB` health check に寄せます。

---

## 10-0-4. `infra/codedeploy.tf` を作る

`infra/codedeploy.tf` を作成します。

```hcl id="xqz677"
resource "aws_codedeploy_app" "app" {
  name             = "${local.name_prefix}-app"
  compute_platform = "Server"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-codedeploy-app"
  })
}

resource "aws_codedeploy_deployment_group" "app" {
  app_name              = aws_codedeploy_app.app.name
  deployment_group_name = "${local.name_prefix}-dg"
  service_role_arn     = aws_iam_role.codedeploy.arn

  # この教材の前半では、まず in-place deployment でCI/CDを体験する
  deployment_style {
    deployment_type   = "IN_PLACE"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }

  # Auto Scaling Group 配下のEC2をデプロイ対象にする
  autoscaling_groups = [
    aws_autoscaling_group.app.name
  ]

  # ALB Target Group と連携し、デプロイ中のインスタンスを一時的に切り離す
  load_balancer_info {
    target_group_info {
      name = aws_lb_target_group.app.name
    }
  }

  # 1台ずつ更新する。今回のdesired_capacityは1なので、デプロイ中に一時的な停止が起き得る。
  deployment_config_name = "CodeDeployDefault.OneAtATime"

  auto_rollback_configuration {
    enabled = true

    events = [
      "DEPLOYMENT_FAILURE"
    ]
  }

  depends_on = [
    aws_iam_role_policy_attachment.codedeploy_service_role,
    aws_lb_listener.http,
    aws_autoscaling_group.app
  ]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-codedeploy-dg"
  })
}
```

---

## 10-0-5. `codedeploy.tf` の解説

## CodeDeploy Application

```hcl id="kg1330"
resource "aws_codedeploy_app" "app" {
  name             = "${local.name_prefix}-app"
  compute_platform = "Server"
}
```

`compute_platform = "Server"` は、EC2 / オンプレミス向けの CodeDeploy Application であることを意味します。

今回の対象は EC2 なので、`Server` を使います。

---

## CodeDeploy Deployment Group

```hcl id="3uobii"
resource "aws_codedeploy_deployment_group" "app" {
  app_name              = aws_codedeploy_app.app.name
  deployment_group_name = "${local.name_prefix}-dg"
  service_role_arn     = aws_iam_role.codedeploy.arn
}
```

Deployment Group は、どのEC2群に、どういう方式でデプロイするかを定義するリソースです。

今回のデプロイ対象は Auto Scaling Group です。

```hcl id="mw7syz"
autoscaling_groups = [
  aws_autoscaling_group.app.name
]
```

---

## in-place deployment

```hcl id="2etj8s"
deployment_style {
  deployment_type   = "IN_PLACE"
  deployment_option = "WITH_TRAFFIC_CONTROL"
}
```

これは、既存EC2上でアプリを入れ替える構成です。

`WITH_TRAFFIC_CONTROL` を使うことで、CodeDeploy が ALB Target Group と連携します。

今回の構成では、デプロイ中に対象インスタンスが一時的に Target Group から外されることがあります。

desired capacity が1台なので、デプロイ中に一時的にアクセスできない時間が出る可能性があります。

これは、この段階では許容します。

```text id="uiug9m"
この段階:
  in-place deployment の仕組みを理解する

後続:
  Blue/Green deployment で停止時間を小さくする
```

---

## ALB Target Group との連携

```hcl id="uclib2"
load_balancer_info {
  target_group_info {
    name = aws_lb_target_group.app.name
  }
}
```

CodeDeploy が ALB Target Group と連携するための設定です。

これにより、CodeDeploy はデプロイ対象インスタンスをロードバランサーの通信対象から外したり、完了後に戻したりできます。

---

## 自動ロールバック

```hcl id="91yo5e"
auto_rollback_configuration {
  enabled = true

  events = [
    "DEPLOYMENT_FAILURE"
  ]
}
```

デプロイが失敗した場合に、自動ロールバックを試みます。

ただし、これは「絶対に無停止で安全」という意味ではありません。

特に in-place deployment では、既存EC2上でアプリを入れ替えるため、失敗の仕方によって一時的にアプリが止まることがあります。

---

## 10-0-6. CodeDeploy Agent の前提確認

第8章の `asg.tf` の `user_data` で、EC2 起動時に CodeDeploy Agent を入れている必要があります。

`aws_launch_template.app` の `user_data` に、最低限以下が含まれていることを確認してください。

```bash id="l9qqev"
dnf update -y
dnf install -y ruby wget curl

cd /tmp

wget https://aws-codedeploy-${var.aws_region}.s3.${var.aws_region}.amazonaws.com/latest/install
chmod +x ./install
./install auto

systemctl enable --now codedeploy-agent
systemctl status codedeploy-agent --no-pager || true
```

この処理はローカルPCで実行するものではありません。

```text id="wzxgsu"
ローカルPC:
  asg.tf に user_data として書く

AWS:
  EC2 起動時に cloud-init 経由で実行される
```

CodeDeploy Agent が入っていないと、CodeDeploy は EC2 上で `appspec.yml` や `scripts/*.sh` を実行できません。

---

## 10-0-7. ここで Terraform を実行する

ここまでで、`outputs.tf` が参照していた CodeDeploy リソースも定義できました。

そのため、このタイミングで初めて Terraform の確認と作成を行います。

## 作業場所

```text id="tbzjbz"
ローカルPC
```

## 対象ディレクトリ

```text id="buomjr"
terraform-aws-cicd-tutorial/infra/
```

## 実行コマンド

```bash id="vvatlg"
cd infra
terraform fmt
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

## 確認する output

```bash id="44bcew"
terraform output
```

少なくとも以下が表示されることを確認します。

```text id="rgm22d"
alb_dns_name
artifact_bucket
codedeploy_app_name
codedeploy_deployment_group_name
github_actions_role_arn
```

個別に確認する場合は以下です。

```bash id="zg5gto"
terraform output -raw alb_dns_name
terraform output -raw artifact_bucket
terraform output -raw codedeploy_app_name
terraform output -raw codedeploy_deployment_group_name
terraform output -raw github_actions_role_arn
```

この時点では、ALB の URL にアクセスしてもアプリはまだ表示されない可能性があります。

理由は、まだ GitHub Actions から v1 をデプロイしていないためです。

```text id="6coo35"
Terraform apply:
  AWS基盤を作っただけ

まだ未実施:
  アプリv1のデプロイ
```

---

# 11. GitHub Actions の CI/CD

## 11-1. この章でやること

この章では、GitHub Actions の workflow を作ります。

ただし、この章では **まだ push しません**。

理由は、`main` ブランチへ push すると、GitHub Actions がすぐに動いて AWS へデプロイしようとするためです。

この章では、以下だけを行います。

```text id="tmefjo"
1. GitHub Actions Variables を設定する
2. appspec.yml を最終確認する
3. ci-cd.yml を作成する
4. ローカルで commit する
5. push は第12章で行う
```

---

## 作業場所

```text id="vmotsy"
ローカルPC
GitHub
```

## 対象ファイル

```text id="9e4g22"
deploy/appspec.yml
.github/workflows/ci-cd.yml
```

## GitHub上で設定するもの

```text id="ty6xus"
Repository Variables
```

---

## 11-2. GitHub Actions Variables を設定する

## 作業場所

```text id="46q3ap"
GitHub
ローカルPC
```

## 操作場所

GitHub 上で、対象リポジトリを開きます。

```text id="s4mq5o"
GitHub Repository
  → Settings
  → Secrets and variables
  → Actions
  → Variables
```

## 作る Variables

以下の4つを作ります。

```text id="c0o6ep"
AWS_GITHUB_ACTIONS_ROLE_ARN
ARTIFACT_BUCKET
CODEDEPLOY_APP_NAME
CODEDEPLOY_DEPLOYMENT_GROUP_NAME
```

## 値の取得元

ローカルPCで Terraform output を確認します。

```bash id="zso9kw"
cd infra

terraform output -raw github_actions_role_arn
terraform output -raw artifact_bucket
terraform output -raw codedeploy_app_name
terraform output -raw codedeploy_deployment_group_name
```

GitHub Variables に、以下の対応で登録します。

```text id="70ghdd"
AWS_GITHUB_ACTIONS_ROLE_ARN:
  terraform output -raw github_actions_role_arn の値

ARTIFACT_BUCKET:
  terraform output -raw artifact_bucket の値

CODEDEPLOY_APP_NAME:
  terraform output -raw codedeploy_app_name の値

CODEDEPLOY_DEPLOYMENT_GROUP_NAME:
  terraform output -raw codedeploy_deployment_group_name の値
```

ここで登録するのは Secrets ではなく Variables で構いません。

これらはパスワードではないためです。

ただし、以下は登録しません。

```text id="y8ogc1"
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

この教材では、GitHub Actions OIDC を使います。

---

## 11-3. `deploy/appspec.yml` を最終確認する

## 作業場所

```text id="2q2s2c"
ローカルPC
```

## 対象ファイル

```text id="5460y6"
deploy/appspec.yml
```

## 目的

CodeDeploy のリビジョン zip では、`appspec.yml` が zip のルートに置かれている必要があります。

今回の zip は、後で GitHub Actions により以下のような構造になります。

```text id="vfextc"
revision.zip
├── appspec.yml
├── app/
│   └── tutorial-app
└── scripts/
    ├── install.sh
    ├── start.sh
    ├── stop.sh
    └── validate.sh
```

`deploy/appspec.yml` を以下の内容にします。

```yaml id="o9fx6g"
version: 0.0
os: linux

files:
  - source: app
    destination: /opt/tutorial-app

file_exists_behavior: OVERWRITE

hooks:
  BeforeInstall:
    - location: scripts/stop.sh
      timeout: 60
      runas: root

  AfterInstall:
    - location: scripts/install.sh
      timeout: 120
      runas: root

  ApplicationStart:
    - location: scripts/start.sh
      timeout: 60
      runas: root

  ValidateService:
    - location: scripts/validate.sh
      timeout: 60
      runas: root
```

`file_exists_behavior: OVERWRITE` は、デプロイ先に既存ファイルがある場合に上書きするための設定です。

学習中に手動でファイルが残った場合や、再デプロイ時の失敗を減らすために入れています。

---

## 11-4. `ci-cd.yml` を作る

## 作業場所

```text id="5p4zdp"
ローカルPC
```

## 対象ファイル

```text id="625akt"
.github/workflows/ci-cd.yml
```

## この workflow の動き

```text id="cwwa6s"
Pull Request:
  go test ./...

main ブランチへの push:
  go test ./...
  go build
  revision.zip 作成
  GitHub Actions OIDC で AWS Role を引き受ける
  S3へ revision.zip をアップロード
  CodeDeploy deployment を作成
  deployment 成功を待つ
```

`.github/workflows/ci-cd.yml` を作成します。

```yaml id="uu8fle"
name: ci-cd

on:
  pull_request:
    branches:
      - main

  push:
    branches:
      - main

permissions:
  id-token: write
  contents: read

env:
  AWS_REGION: ap-northeast-1

jobs:
  test:
    runs-on: ubuntu-latest

    defaults:
      run:
        working-directory: app

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Go
        uses: actions/setup-go@v5
        with:
          go-version-file: app/go.mod

      - name: Test
        run: go test ./...

  deploy:
    if: github.event_name == 'push'
    needs: test
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Go
        uses: actions/setup-go@v5
        with:
          go-version-file: app/go.mod

      - name: Build Linux binary
        working-directory: app
        run: |
          GOOS=linux GOARCH=amd64 go build -o tutorial-app .

      - name: Package CodeDeploy revision
        run: |
          rm -rf package revision.zip
          mkdir -p package/app
          cp app/tutorial-app package/app/tutorial-app
          cp deploy/appspec.yml package/appspec.yml
          cp -r deploy/scripts package/scripts
          cd package
          zip -r ../revision.zip .

      - name: Configure AWS credentials with OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_GITHUB_ACTIONS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Check AWS caller identity
        run: |
          aws sts get-caller-identity

      - name: Upload artifact to S3
        run: |
          aws s3 cp revision.zip \
            s3://${{ vars.ARTIFACT_BUCKET }}/revisions/${{ github.sha }}.zip

      - name: Create CodeDeploy deployment
        run: |
          DEPLOYMENT_ID=$(aws deploy create-deployment \
            --application-name "${{ vars.CODEDEPLOY_APP_NAME }}" \
            --deployment-group-name "${{ vars.CODEDEPLOY_DEPLOYMENT_GROUP_NAME }}" \
            --s3-location bucket=${{ vars.ARTIFACT_BUCKET }},key=revisions/${{ github.sha }}.zip,bundleType=zip \
            --description "GitHub Actions deployment for commit ${{ github.sha }}" \
            --query deploymentId \
            --output text)

          echo "DEPLOYMENT_ID=$DEPLOYMENT_ID" >> "$GITHUB_ENV"
          echo "Created deployment: $DEPLOYMENT_ID"

      - name: Wait for CodeDeploy deployment
        run: |
          aws deploy wait deployment-successful \
            --deployment-id "$DEPLOYMENT_ID"
```

---

## 11-5. この章では commit だけする

この章では、まだ `git push` しません。
push は第12章で行います。

ローカルPCで以下を実行します。

```bash id="f8i4m4"
git add deploy/appspec.yml .github/workflows/ci-cd.yml
git commit -m "add GitHub Actions CI/CD workflow"
```

すでに commit 済みで変更がない場合は、commit は不要です。

確認します。

```bash id="624v5e"
git status
```

まだ未pushのcommitがある状態で問題ありません。

```text id="d8w7or"
第11章:
  workflowを作る
  GitHub Variablesを設定する
  commitする
  まだpushしない

第12章:
  mainへpushしてv1をデプロイする
```

---

# 12. v1 をデプロイする

## 12-1. この章でやること

この章では、最初のアプリバージョンである v1 を AWS にデプロイします。

ここで初めて、`main` ブランチへ push します。

push すると、GitHub Actions が動き、CodeDeploy によって EC2 へアプリが配布されます。

---

## 作業場所

```text id="ij8zcj"
ローカルPC
GitHub
AWS Console
ブラウザまたはcurl
```

## 対象ファイル

```text id="6junz0"
app/main.go
app/main_test.go
deploy/appspec.yml
deploy/scripts/*.sh
.github/workflows/ci-cd.yml
```

## 事前に完了している必要があるもの

```text id="cnzb4t"
Terraform apply が成功している
GitHub Actions Variables を設定済み
CodeDeploy Application / Deployment Group が作成済み
ASG配下のEC2が起動している
CodeDeploy Agent がEC2に入っている
```

---

## 12-2. v1 の状態を確認する

`app/main.go` を確認します。

```go id="ke33so"
var version = "v1"
```

`/health` が正常に `OK` を返すことも確認します。

```go id="1eorql"
mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintln(w, "OK")
})
```

ローカルPCでテストします。

```bash id="i1olpk"
cd app
go test ./...
cd ..
```

ローカルで起動確認してもよいです。

```bash id="ngtseg"
cd app
go run main.go
```

別ターミナルで確認します。

```bash id="maws6z"
curl http://localhost:8080/
curl http://localhost:8080/health
curl http://localhost:8080/version
```

期待結果:

```text id="5xw9xe"
Hello from tutorial app v1
OK
v1
```

確認できたら、ローカルのアプリを停止します。

---

## 12-3. commit する

ローカルPCで、変更内容を確認します。

```bash id="mhsgax"
git status --short
```

まだ commit していないファイルがある場合は、commit します。

```bash id="vdoblp"
git add app deploy .github infra
git reset infra/terraform.tfvars || true
git commit -m "deploy app v1"
```

`infra/terraform.tfvars` は個人環境の値を含むため、Gitに入れない方針にしています。

すでに commit 済みの場合は、以下のように表示されます。

```text id="sye1jv"
nothing to commit, working tree clean
```

その場合は、そのまま次へ進みます。

---

## 12-4. main ブランチへ push する

ここで初めて push します。

```bash id="v2h1su"
git push origin main
```

この push をきっかけに、GitHub Actions が起動します。

---

## 12-5. 何が起きるか

`git push` 後、以下が自動で実行されます。

```text id="nd5g9c"
1. GitHub Actions が起動する
2. test job で go test ./... が実行される
3. deploy job が開始される
4. Goアプリが Linux 用にビルドされる
5. revision.zip が作成される
6. GitHub Actions が OIDC で AWS Role を引き受ける
7. aws sts get-caller-identity でAWS接続を確認する
8. revision.zip が S3 にアップロードされる
9. CodeDeploy deployment が作成される
10. EC2上のCodeDeploy Agentがrevision.zipを取得する
11. appspec.yml に従って scripts/*.sh が実行される
12. tutorial-app が systemd サービスとして起動する
13. validate.sh が /health を確認する
14. 成功すれば deployment が成功になる
```

---

## 12-6. GitHub Actions を確認する

## 作業場所

```text id="on7atx"
GitHub
```

## 操作場所

```text id="5xb284"
GitHub Repository
  → Actions
```

`ci-cd` workflow を開きます。

以下を確認します。

```text id="zl6fhe"
test job が成功している
deploy job が成功している
Check AWS caller identity が成功している
Upload artifact to S3 が成功している
Wait for CodeDeploy deployment が成功している
```

もし `Configure AWS credentials with OIDC` で失敗した場合は、以下を確認します。

```text id="2ud15o"
GitHub Variables の AWS_GITHUB_ACTIONS_ROLE_ARN が正しいか
github_owner / github_repo が terraform.tfvars と一致しているか
main ブランチから実行しているか
permissions に id-token: write があるか
```

---

## 12-7. S3 artifact を確認する

## 作業場所

```text id="at60i9"
AWS Console
```

## 操作場所

```text id="9eljqk"
AWS Console
  → S3
  → artifact bucket
  → revisions/
```

以下のようなファイルがあることを確認します。

```text id="jltvp8"
revisions/<commit-sha>.zip
```

この zip が、CodeDeploy に渡されるアプリ成果物です。

---

## 12-8. CodeDeploy を確認する

## 作業場所

```text id="fz9os6"
AWS Console
```

## 操作場所

```text id="lzd8a2"
AWS Console
  → CodeDeploy
  → Applications
  → 対象Application
  → Deployment groups
  → Deployments
```

Deployment が `Succeeded` になっていることを確認します。

失敗している場合は、Deployment の詳細画面を開きます。

よく見るポイントは以下です。

```text id="j3zys8"
どの lifecycle event で失敗したか
BeforeInstall か
AfterInstall か
ApplicationStart か
ValidateService か
```

---

## 12-9. ALB 経由で v1 を確認する

## 作業場所

```text id="zzh1do"
ローカルPC
ブラウザまたはcurl
```

ALB DNS名を確認します。

```bash id="tt244t"
cd infra
terraform output -raw alb_dns_name
```

curl で確認します。

```bash id="rgket6"
curl http://$(terraform output -raw alb_dns_name)/
curl http://$(terraform output -raw alb_dns_name)/health
curl http://$(terraform output -raw alb_dns_name)/version
```

期待結果:

```text id="gtpiu0"
Hello from tutorial app v1
OK
v1
```

ブラウザでも確認できます。

```text id="xfokdz"
http://<alb-dns-name>/
```

---

## 12-10. EC2 内で確認する場合

必要に応じて、SSM Session Manager で EC2 に入って確認します。

## 作業場所

```text id="esxiry"
AWS Console
または
ローカルPCのAWS CLI
```

AWS Console の場合:

```text id="onlgc8"
AWS Console
  → Systems Manager
  → Session Manager
```

EC2内で確認します。

```bash id="rikckq"
systemctl status tutorial-app --no-pager
curl http://localhost:8080/health
curl http://localhost:8080/version
journalctl -u tutorial-app --no-pager -n 100
```

期待結果:

```text id="lr8sgj"
OK
v1
```

CodeDeploy Agent のログを見る場合:

```bash id="7n2ueb"
sudo cat /var/log/aws/codedeploy-agent/codedeploy-agent.log
```

---

# 13. v2 にバージョンアップする

## 13-1. この章でやること

この章では、アプリを v1 から v2 に変更し、CI/CD によって自動デプロイされることを確認します。

ここでは Terraform は実行しません。

```text id="9ic9mm"
Terraform:
  実行しない

GitHub Actions:
  git push によって起動する

CodeDeploy:
  v2のartifactをEC2へ配布する
```

アプリのバージョンアップは、Terraform ではなく CI/CD の仕事です。

---

## 作業場所

```text id="q31cny"
ローカルPC
GitHub
AWS Console
ブラウザまたはcurl
```

## 対象ファイル

```text id="yyceqw"
app/main.go
```

---

## 13-2. アプリを v2 に変更する

`app/main.go` を編集します。

変更前:

```go id="vz8x5t"
var version = "v1"
```

変更後:

```go id="k4vqxl"
var version = "v2"
```

`/health` は正常なままにします。

```go id="pjy1zs"
mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintln(w, "OK")
})
```

---

## 13-3. ローカルでテストする

```bash id="aql5ra"
cd app
go test ./...
cd ..
```

必要ならローカルで起動確認します。

```bash id="pzxmqt"
cd app
go run main.go
```

別ターミナルで確認します。

```bash id="ff4hz3"
curl http://localhost:8080/version
```

期待結果:

```text id="2mv1m7"
v2
```

確認できたら、ローカルのアプリを停止します。

---

## 13-4. commit / push する

```bash id="xbigza"
git add app/main.go
git commit -m "release app v2"
git push origin main
```

---

## 13-5. 何が起きるか

```text id="fe28b4"
1. GitHub Actions が起動する
2. go test ./... が実行される
3. v2 のLinuxバイナリがビルドされる
4. v2 の revision.zip が作られる
5. S3 の revisions/<commit-sha>.zip にアップロードされる
6. CodeDeploy deployment が作成される
7. EC2 上で既存の tutorial-app が停止される
8. v2 の tutorial-app が /opt/tutorial-app に配置される
9. systemd で tutorial-app が再起動される
10. ValidateService で /health が確認される
11. 成功すれば deployment が成功になる
```

---

## 13-6. GitHub Actions を確認する

```text id="yndwur"
GitHub Repository
  → Actions
  → ci-cd
```

以下を確認します。

```text id="44fr8d"
test 成功
build 成功
S3 upload 成功
CodeDeploy deployment 作成成功
deployment wait 成功
```

---

## 13-7. CodeDeploy を確認する

```text id="6azg7s"
AWS Console
  → CodeDeploy
  → Applications
  → 対象Application
  → Deployments
```

新しい Deployment が `Succeeded` になっていることを確認します。

---

## 13-8. ALB 経由で v2 を確認する

ローカルPCで実行します。

```bash id="wq7tdq"
cd infra
curl http://$(terraform output -raw alb_dns_name)/version
```

期待結果:

```text id="ddsd3s"
v2
```

トップページも確認します。

```bash id="h76oc0"
curl http://$(terraform output -raw alb_dns_name)/
```

期待結果:

```text id="2pcjt2"
Hello from tutorial app v2
```

これで、アプリの v1 → v2 バージョンアップを CI/CD で流せました。

---

## 13-9. この章で理解すべきこと

この章で重要なのは、以下です。

```text id="d2jrju"
アプリコード変更:
  app/main.go

デプロイ開始:
  git push

テスト・ビルド:
  GitHub Actions

成果物保存:
  S3

EC2への配布:
  CodeDeploy

インフラ変更:
  していない
```

つまり、v1 → v2 のアプリ更新で `terraform apply` は実行していません。

これが、Terraform と CI/CD の役割分担です。

---

# 14. わざと失敗させる

## 14-1. この章でやること

この章では、アプリの health check をわざと壊して、デプロイ失敗がどこで検知されるか確認します。

目的は、以下を体験することです。

```text id="y8m8qw"
テストだけでは検知できない問題がある
デプロイ後のhealth checkが重要
CodeDeployのValidateServiceで失敗を検知できる
失敗時にGitHub Actionsも失敗になる
auto rollbackが動く可能性がある
```

---

## 作業場所

```text id="nsszi1"
ローカルPC
GitHub
AWS Console
必要に応じてSSM Session Manager
```

## 対象ファイル

```text id="m5256u"
app/main.go
```

---

## 14-2. 重要な注意

この章は、まだ in-place deployment の段階です。

```text id="jyipz0"
in-place deployment:
  既存EC2上でアプリを入れ替える

Blue/Green deployment:
  新しい環境にデプロイしてから切り替える
```

今回の in-place deployment では、デプロイ失敗時に CodeDeploy の rollback を設定しています。

ただし、in-place では既存EC2上でアプリを入れ替えるため、失敗の仕方によっては一時的にアプリが止まる可能性があります。

したがって、ここでは次のように理解します。

```text id="9cvfni"
正しい理解:
  失敗を検知できる
  rollbackを試みられる
  ただし無停止を保証するものではない

間違った理解:
  CodeDeployなら必ず無停止
  CodeDeployなら必ず本番影響ゼロ
```

無停止に近づける設計は、後続の Blue/Green で扱います。

---

## 14-3. `/health` を壊す

`app/main.go` を編集します。

変更前:

```go id="2y752z"
mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintln(w, "OK")
})
```

変更後:

```go id="e6r9kt"
mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
	http.Error(w, "NG", http.StatusInternalServerError)
})
```

この変更により、アプリは起動しますが、`/health` は HTTP 500 を返します。

---

## 14-4. ローカルで確認する

ローカルでテストします。

```bash id="k06ipx"
cd app
go test ./...
```

このテストは成功する可能性があります。

理由は、現在の `main_test.go` は `version` が空でないことしか見ていないためです。

```text id="glry3r"
go test:
  成功する可能性がある

/health:
  実行時には失敗する
```

ローカルで起動して確認します。

```bash id="3k1qv9"
go run main.go
```

別ターミナルで確認します。

```bash id="akotyq"
curl -i http://localhost:8080/health
```

期待結果:

```text id="rk001f"
HTTP/1.1 500 Internal Server Error
```

確認できたら、ローカルのアプリを停止します。

---

## 14-5. commit / push する

```bash id="tixpcm"
git add app/main.go
git commit -m "break health check"
git push origin main
```

---

## 14-6. 何が起きるか

```text id="7vknbn"
1. GitHub Actions が起動する
2. go test は成功する可能性がある
3. アプリがビルドされる
4. revision.zip がS3にアップロードされる
5. CodeDeploy deployment が作成される
6. EC2上でアプリが入れ替わる
7. ApplicationStart でアプリは起動する
8. ValidateService で validate.sh が実行される
9. validate.sh が /health を確認する
10. /health がHTTP 500を返す
11. ValidateService が失敗する
12. CodeDeploy deployment が失敗になる
13. GitHub Actions の Wait for CodeDeploy deployment も失敗になる
14. auto rollback が有効なら、前回成功したrevisionへのrollbackを試みる
```

---

## 14-7. GitHub Actions の失敗を確認する

```text id="u76q86"
GitHub Repository
  → Actions
  → failed workflow
```

`Wait for CodeDeploy deployment` が失敗していることを確認します。

これは期待通りです。

```text id="q97goh"
この章では失敗させるのが目的
```

---

## 14-8. CodeDeploy の失敗を確認する

```text id="exnkhz"
AWS Console
  → CodeDeploy
  → Applications
  → 対象Application
  → Deployments
```

失敗した Deployment を開きます。

確認するポイントは以下です。

```text id="6aoy37"
失敗した lifecycle event:
  ValidateService

実行された script:
  scripts/validate.sh

失敗理由:
  /health がHTTP 200を返さなかった
```

---

## 14-9. EC2内のログを確認する

必要に応じて、SSM Session Manager で EC2 に入ります。

```text id="qz9duy"
AWS Console
  → Systems Manager
  → Session Manager
```

EC2内で確認します。

```bash id="9sary2"
systemctl status tutorial-app --no-pager
journalctl -u tutorial-app --no-pager -n 100
sudo cat /var/log/aws/codedeploy-agent/codedeploy-agent.log
```

アプリ自体は起動しているが、`/health` が失敗している可能性があります。

```bash id="09hsrh"
curl -i http://localhost:8080/health
curl -i http://localhost:8080/version
```

---

## 14-10. rollback 後の状態を確認する

第13章で v2 のデプロイが成功していた場合、CodeDeploy は失敗時に前回成功した revision への rollback を試みます。

ALB 経由で確認します。

```bash id="a25tuw"
cd infra
curl http://$(terraform output -raw alb_dns_name)/version
curl -i http://$(terraform output -raw alb_dns_name)/health
```

期待される状態は、前回成功した v2 に戻っていることです。

```text id="x2hk8e"
version:
  v2

health:
  HTTP 200 / OK
```

ただし、rollback にも失敗した場合は、手動で正常版を再デプロイする必要があります。

---

## 14-11. 正常版に戻す

壊した `/health` を元に戻します。

`app/main.go` を編集します。

```go id="ec0hlq"
mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintln(w, "OK")
})
```

version は v2 のままで構いません。

```go id="jmj5au"
var version = "v2"
```

ローカルで確認します。

```bash id="sfhkfh"
cd app
go test ./...
cd ..
```

commit / push します。

```bash id="brim7i"
git add app/main.go
git commit -m "restore health check"
git push origin main
```

GitHub Actions と CodeDeploy が成功することを確認します。

最後に ALB 経由で確認します。

```bash id="358xlk"
cd infra
curl http://$(terraform output -raw alb_dns_name)/health
curl http://$(terraform output -raw alb_dns_name)/version
```

期待結果:

```text id="cdlyri"
OK
v2
```

---

## 14-12. この章で理解すべきこと

この章で重要なのは、以下です。

```text id="df3fia"
CIのテストだけでは、実行時のhealth check不良を検知できないことがある。

CodeDeployのValidateServiceで、デプロイ後の実行時確認ができる。

in-place deploymentでは、失敗検知やrollbackはできるが、
無停止を保証するわけではない。

Blue/Green deploymentは、
新環境で検証してから切り替えるための次のステップである。
```

つまり、この章は Blue/Green の必要性を理解するための前段です。

```text id="lg9ht0"
in-placeで失敗を体験する
  ↓
なぜBlue/Greenが必要か理解する
  ↓
後続章でBlue/Greenを学ぶ
```


# 15. Blue/Green デプロイの説明

## 15-1. この章でやること

この章では、Blue/Green デプロイの概念を理解します。

## 作業場所

```text
概念説明中心
必要に応じて AWS Console で確認
```

## 関係するAWSリソース

```text
ALB
Target Group
Auto Scaling Group
CodeDeploy Deployment Group
```

---

## 15-2. Blue/Green とは

Blue/Green デプロイとは、現在動いている環境とは別に新しい環境を用意し、動作確認後にトラフィックを切り替えるデプロイ方式です。

```text
Blue:
  現在本番として動いている環境

Green:
  新しいバージョンを入れる環境
```

---

## 15-3. 図で理解する

## 変更前

```text
Internet
  ↓
ALB
  ↓
Blue EC2 Group
  ↓
App v1
```

## デプロイ中

```text
Internet
  ↓
ALB
  ├── Blue EC2 Group  -> App v1
  └── Green EC2 Group -> App v2
```

## 切り替え後

```text
Internet
  ↓
ALB
  ↓
Green EC2 Group
  ↓
App v2
```

---

## 15-4. Blue/Green のメリット

```text
新環境で事前に動作確認できる
問題があれば旧環境に戻しやすい
切り替え時間を短くしやすい
サーバーを使い回さないため環境差分が出にくい
```

---

## 15-5. Blue/Green の注意点

```text
一時的にリソースが増える
構成が複雑になる
DB migrationとの相性を考える必要がある
セッション管理を考える必要がある
```

特に、データベース変更がある場合は注意が必要です。

アプリ v2 が DB スキーマを変更し、v1 に戻れない状態にすると、Blue/Green でも簡単にはロールバックできません。

---

# 16. Terraform と Blue/Green の境界

## 16-1. この章でやること

この章では、Blue/Green における Terraform と CodeDeploy の責務の違いを整理します。

## 作業場所

```text
概念説明中心
Terraformコード上では infra/codedeploy.tf が関係する
```

## 対象ファイル

```text
infra/codedeploy.tf
infra/alb.tf
infra/asg.tf
```

---

## 16-2. Terraform が管理するもの

Terraform は、Blue/Green デプロイを実行できる基盤を作ります。

```text
ALB
Target Group
Auto Scaling Group
CodeDeploy Application
CodeDeploy Deployment Group
IAM Role
S3 Artifact Bucket
```

---

## 16-3. Terraform が毎回管理しないもの

Terraform は、毎回のデプロイ実行そのものは管理しません。

```text
個々の deployment 実行
一時的な Green 環境
デプロイ履歴
現在進行中の切り替え処理
```

これらは CodeDeploy が扱います。

---

## 16-4. 役割分担

```text
Terraform:
  Blue/Green ができるAWS基盤を定義する

GitHub Actions:
  テスト、ビルド、artifact作成、CodeDeploy起動を行う

CodeDeploy:
  実際のデプロイ、health check、切り替え、失敗検知を行う
```

この分担を守ることで、インフラ管理とアプリリリースが混ざりにくくなります。

---

# 17. Web デプロイのベストプラクティス

## 17-1. この章でやること

ここでは、今回の構成で学べる Web デプロイの基本方針を整理します。

## 作業場所

```text
概念説明中心
必要に応じてTerraformコードに反映
```

---

## 17-2. EC2 を直接公開しない

学習初期は EC2 に直接アクセスする構成でも理解しやすいですが、本番寄りでは ALB 経由にします。

```text
Internet
  ↓
ALB
  ↓
EC2
```

EC2 の Security Group では、ALB からの通信だけを許可します。

---

## 17-3. SSH を公開しない

悪い例:

```text
TCP 22 from 0.0.0.0/0
```

この教材では、SSH を開けません。

必要な場合は SSM Session Manager を使います。

---

## 17-4. health check を用意する

アプリには必ず health check endpoint を用意します。

```text
GET /health -> OK
```

ALB や CodeDeploy は、この endpoint を使って正常性を確認します。

---

## 17-5. テストなしでデプロイしない

悪い例:

```text
pushしたら即デプロイ
```

良い例:

```text
push
  ↓
test
  ↓
build
  ↓
package
  ↓
deploy
```

---

## 17-6. 成果物を保存する

デプロイ対象は、zip やコンテナイメージなどの成果物として保存します。

この教材では S3 に保存します。

```text
S3:
  revisions/<commit-sha>.zip
```

---

## 17-7. ロールバックを前提にする

デプロイは失敗します。

その前提で設計します。

```text
health check
deployment history
automatic rollback
Blue/Green
old artifact
```

---

## 17-8. 長期アクセスキーを使わない

GitHub Actions から AWS に接続するために、長期アクセスキーを GitHub Secrets に置く構成は避けます。

```text
使わない:
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY

使う:
  GitHub Actions OIDC
  AWS IAM Role
```

---

# 18. 料金面の注意

## 18-1. この章でやること

この章では、チュートリアルで発生し得る料金に注意します。

## 作業場所

```text
AWS Console
ローカルPC
```

---

## 18-2. 料金が発生し得るリソース

この教材では、以下で料金が発生する可能性があります。

```text
EC2
EBS
ALB
S3
CloudWatch Logs
CodeDeploy関連の周辺利用
```

特に注意するもの:

```text
ALB:
  作ったまま放置すると課金される

NAT Gateway:
  この教材では基本的に使わない
  追加した場合は放置に注意

S3:
  artifact zip が溜まり続ける
```

---

## 18-3. Budgets を設定する

AWS Console で Billing / Budgets を確認し、学習用の予算アラートを設定します。

```text
AWS Console
  → Billing and Cost Management
  → Budgets
```

---

# 19. クリーンアップ

## 19-1. この章でやること

この章では、Terraform で作成した AWS リソースを削除します。

## 作業場所

```text
ローカルPC
AWS Console
```

## 対象ディレクトリ

```text
terraform-aws-cicd-tutorial/infra/
```

---

## 19-2. Terraform destroy を実行する

ローカルPCで実行します。

```bash
cd infra
terraform destroy
```

確認が表示されたら、内容を確認して `yes` を入力します。

---

## 19-3. S3 バケットで destroy が失敗した場合

S3 バケットに artifact zip が残っていると、削除に失敗する場合があります。

その場合は、S3 内の artifact を削除してから再度実行します。

```text
AWS Console
  → S3
  → artifact bucket
  → revisions/ 配下を削除
```

その後、再実行します。

```bash
terraform destroy
```

---

## 19-4. 削除確認

AWS Console で以下を確認します。

```text
EC2 Instance が残っていない
Auto Scaling Group が残っていない
Launch Template が不要なら残っていない
ALB が残っていない
Target Group が残っていない
S3 Bucket が不要なら残っていない
CodeDeploy Application が残っていない
IAM Role が不要なら残っていない
```

---

# 20. この教材で得られる理解

このチュートリアルを終えると、以下が理解できます。

## AWS 基礎

```text
Region
Availability Zone
VPC
Subnet
Route Table
Internet Gateway
Security Group
EC2
IAM
```

## Web デプロイ基礎

```text
ALB
Target Group
Health Check
Auto Scaling Group
systemd
application artifact
```

## Terraform

```text
provider
resource
variable
output
state
plan
apply
destroy
```

## CI/CD

```text
GitHub Actions
test
build
package
OIDC
S3 artifact
CodeDeploy
```

## Blue/Green

```text
Blue 環境
Green 環境
traffic switching
rollback
health check
```

---

# 21. 発展課題

## 21-1. EC2 を Private Subnet に移す

本番寄りの構成では、EC2 は Private Subnet に置きます。

```text
Internet
  ↓
ALB in Public Subnet
  ↓
EC2 in Private Subnet
```

この場合、EC2 が外部サービスへ出るために、以下を検討します。

```text
NAT Gateway
VPC Endpoint
```

---

## 21-2. HTTPS 化する

ALB に ACM 証明書を付け、HTTPS で公開します。

```text
HTTP  -> HTTPS にリダイレクト
HTTPS -> ALB -> EC2
```

---

## 21-3. CloudWatch Logs に送る

アプリログを CloudWatch Logs に送ります。

```text
journalctl
  ↓
CloudWatch Agent
  ↓
CloudWatch Logs
```

---

## 21-4. ECS / Fargate 化する

EC2 + systemd を理解した後、コンテナ化に進みます。

```text
EC2 + systemd
  ↓
Docker
  ↓
ECR
  ↓
ECS Fargate
```

---

## 21-5. CodePipeline / CodeBuild を使う

GitHub Actions の代わりに AWS ネイティブ構成へ寄せる場合は、以下を使います。

```text
CodePipeline
CodeBuild
CodeDeploy
```

---

# 22. この教材で避けること

## 22-1. いきなり Kubernetes に行かない

Kubernetes は強力ですが、AWS 基礎理解前に入ると抽象度が高すぎます。

まずは以下を理解します。

```text
VPC
Subnet
Security Group
EC2
ALB
ASG
IAM
```

---

## 22-2. いきなり ECS に行かない

ECS / Fargate は実務では有力ですが、最初の AWS 学習では EC2 の方がオンプレ経験者には対応付けしやすいです。

---

## 22-3. SSH 前提にしない

SSH は便利ですが、本番運用の入口としては開けすぎに注意が必要です。

この教材では、SSH を公開しません。

---

## 22-4. アクセスキーを GitHub に置かない

GitHub Secrets に AWS の長期アクセスキーを置く構成は避けます。

OIDC を使います。

---

## 22-5. Terraform でアプリリリースを毎回やらない

アプリの v1 から v2 への更新は CI/CD の仕事です。

Terraform は、それを可能にする基盤を作ります。

---

# 23. まとめ

この教材の一番重要なメッセージは以下です。

```text
Terraform はインフラをコードで管理する。
CI/CD はアプリを安全に届ける。
CodeDeploy は EC2 上のアプリ更新と切り替えを担当する。
ALB と Health Check は安全な Web デプロイの中心になる。
Blue/Green は失敗しても戻せるための設計である。
```

オンプレ出身者向けに一言でまとめると、こうです。

```text
AWSでは、ネットワーク、FW、LB、サーバー、デプロイ手順を
画面操作ではなくコードとパイプラインで再現できるようにする。
```

このチュートリアルの最終体験は、次です。

```text
v1 を動かす
  ↓
コードを v2 に変える
  ↓
GitHub に push する
  ↓
CI がテストする
  ↓
CodeDeploy が配布する
  ↓
ALB 経由で v2 を確認する
  ↓
壊した場合は health check で失敗を検知する
```

これにより、AWS 基礎、Terraform、CI/CD、Web デプロイのベストプラクティス、Blue/Green デプロイを一本の流れとして理解できます。

