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

VPC、Subnet、Internet Gateway、Route Table を作ります。

オンプレでいうと、以下を作るイメージです。

```text
社内ネットワーク
ネットワークセグメント
インターネット出口
ルーティング設定
```

このチュートリアルでは、学習しやすさを優先し、Public Subnet を2つ作ります。

```text
VPC
├── Public Subnet A
└── Public Subnet C
```

本番では EC2 を Private Subnet に置く構成が一般的ですが、最初から NAT Gateway や VPC Endpoint まで入れると複雑になるため、この教材では次の方針にします。

```text
EC2はPublic Subnetに置く
ただしSSHは開けない
EC2へのアプリ通信はALBからのみ許可する
```

---

## 8-7. `security_group.tf` を作る

## 作業場所

```text
ローカルPC
```

## 対象ファイル

```text
infra/security_group.tf
```

## 目的

ALB 用と EC2 用の Security Group を作ります。

作る Security Group は2つです。

```text
ALB Security Group
EC2 Security Group
```

許可する通信は以下です。

```text
Internet
  -> ALB
     TCP 80

ALB
  -> EC2
     TCP 8080
```

SSH は開けません。

悪い例:

```text
TCP 22 from 0.0.0.0/0
```

この教材では、これは使いません。

EC2 に入る必要がある場合は、SSM Session Manager を使います。

---

## 8-8. `s3.tf` を作る

## 作業場所

```text
ローカルPC
```

## 対象ファイル

```text
infra/s3.tf
```

## 目的

GitHub Actions が作成したアプリの zip ファイルを置く S3 バケットを作ります。

この S3 バケットは、デプロイ成果物置き場です。

```text
GitHub Actions
  ↓
revision.zip
  ↓
S3 Artifact Bucket
  ↓
CodeDeploy
```

成果物は、たとえば以下のようなキーで保存します。

```text
revisions/<commit-sha>.zip
```

これにより、どの Git commit から作られた成果物か追いやすくなります。

---

## 8-9. `alb.tf` を作る

## 作業場所

```text
ローカルPC
```

## 対象ファイル

```text
infra/alb.tf
```

## 目的

Application Load Balancer、Target Group、Listener を作ります。

ALB は、外部からの HTTP アクセスを受ける入口です。

```text
Internet
  ↓
ALB
  ↓
Target Group
  ↓
EC2
```

オンプレでいうと、L7ロードバランサに近いものです。

この教材では、HTTP 80番で受けます。

```text
ブラウザ / curl
  ↓
http://<alb-dns-name>/
```

本番では HTTPS 化しますが、この教材では AWS 基礎と CI/CD の理解を優先し、まず HTTP で進めます。

---

## 8-10. `asg.tf` を作る

## 作業場所

```text
ローカルPC
```

## 対象ファイル

```text
infra/asg.tf
```

## 目的

Launch Template と Auto Scaling Group を作ります。

Launch Template は、EC2 をどう起動するかのテンプレートです。

```text
AMI
instance type
IAM role
Security Group
user_data
```

Auto Scaling Group は、その Launch Template を使って EC2 の台数を維持します。

```text
desired_capacity = 1
min_size         = 1
max_size         = 2
```

この教材では、まず1台構成で動かします。

ただし、EC2を手動で作るのではなく、Auto Scaling Group に管理させるのがポイントです。

```text
悪い学習構成:
  EC2を1台だけ手作業で作る

この教材の構成:
  Launch Template + Auto Scaling GroupでEC2を管理する
```

---

# 9. IAM 設計

## 9-1. この章でやること

この章では、AWS の権限管理である IAM を Terraform で定義します。

## 作業場所

```text
ローカルPC
```

## 対象ファイル

```text
infra/iam.tf
infra/github_oidc.tf
```

## AWS Console でやること

基本的にはありません。
IAM Role や IAM Policy も Terraform で作ります。

## この章で作る IAM Role

```text
EC2 Instance Role
CodeDeploy Service Role
GitHub Actions Role
```

---

## 9-2. EC2 Instance Role

## 作業場所

```text
ローカルPC
```

## 対象ファイル

```text
infra/iam.tf
```

## 目的

EC2 が AWS サービスを使うための Role を作ります。

EC2 には、以下の権限が必要です。

```text
SSM Session Manager を使う
CodeDeploy Agent として動作する
S3 から artifact zip を取得する
```

この Role は、Launch Template 経由で EC2 に付与します。

```text
Launch Template
  ↓
IAM Instance Profile
  ↓
EC2 Instance Role
  ↓
EC2
```

EC2 の中にアクセスキーを置くのではありません。
EC2 に IAM Role を付けることで、一時的な認証情報を使えるようにします。

---

## 9-3. CodeDeploy Service Role

## 作業場所

```text
ローカルPC
```

## 対象ファイル

```text
infra/iam.tf
```

## 目的

CodeDeploy が AWS リソースを操作するための Role を作ります。

CodeDeploy は、デプロイ時に以下を扱います。

```text
Auto Scaling Group
EC2
ALB
Target Group
Deployment 状態
```

つまり、CodeDeploy 自身にも AWS を操作する権限が必要です。

```text
CodeDeploy
  ↓ assume role
CodeDeploy Service Role
  ↓
EC2 / ASG / ALB を操作
```

---

## 9-4. GitHub Actions OIDC Role

## 作業場所

```text
ローカルPC
```

## 対象ファイル

```text
infra/github_oidc.tf
```

## 目的

GitHub Actions から AWS を操作するための Role を作ります。

この教材では、GitHub Secrets に AWS の長期アクセスキーを置きません。

使わないもの:

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

代わりに OIDC を使います。

```text
GitHub Actions
  ↓ OIDC
AWS IAM Role
  ↓
S3 upload / CodeDeploy create-deployment
```

GitHub Actions Role に許可する操作は、主に以下です。

```text
S3 に revision.zip をアップロードする
CodeDeploy の deployment を作成する
CodeDeploy の結果を確認する
```

この Role は、特定の GitHub リポジトリからだけ使えるように制限します。

```text
repo:<github_owner>/<github_repo>:ref:refs/heads/main
```

---

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

# 11. GitHub Actions の CI/CD

## 11-1. この章でやること

この章では、GitHub Actions の workflow を作ります。

## 作業場所

```text
ローカルPC
GitHub
```

## 対象ファイル

```text
.github/workflows/ci-cd.yml
```

## GitHub上で設定するもの

```text
Repository Variables
```

## この章で作る流れ

```text
Pull Request:
  go test ./...

main ブランチへの push:
  go test ./...
  go build
  revision.zip 作成
  S3へアップロード
  CodeDeployを起動
```

---

## 11-2. GitHub Actions Variables を設定する

## 作業場所

```text
GitHub
```

## 操作場所

```text
GitHub Repository
  → Settings
  → Secrets and variables
  → Actions
  → Variables
```

## 作る Variables

```text
AWS_GITHUB_ACTIONS_ROLE_ARN
ARTIFACT_BUCKET
CODEDEPLOY_APP_NAME
CODEDEPLOY_DEPLOYMENT_GROUP_NAME
```

## 値の取得元

ローカルPCで Terraform output を確認します。

```bash
cd infra

terraform output -raw github_actions_role_arn
terraform output -raw artifact_bucket
terraform output -raw codedeploy_app_name
terraform output -raw codedeploy_deployment_group_name
```

それぞれの出力値を GitHub の Variables に登録します。

ここで登録するのは Secrets ではなく Variables で構いません。
Role ARN や S3 バケット名は、パスワードそのものではないためです。

ただし、AWS の長期アクセスキーは登録しません。

---

## 11-3. `ci-cd.yml` を作る

## 作業場所

```text
ローカルPC
```

## 対象ファイル

```text
.github/workflows/ci-cd.yml
```

## 目的

GitHub Actions の workflow を定義します。

この workflow は、以下を行います。

```text
1. ソースを checkout
2. Go をセットアップ
3. go test ./...
4. Go アプリをビルド
5. CodeDeploy 用 zip を作成
6. OIDC で AWS IAM Role を引き受ける
7. zip を S3 にアップロード
8. CodeDeploy deployment を作成
9. deployment 成功を待つ
```

作成後、commit して push します。

```bash
git add .github/workflows/ci-cd.yml
git commit -m "add GitHub Actions CI/CD workflow"
git push origin main
```

## 確認する場所

```text
GitHub Repository
  → Actions
```

Actions が起動しているか確認します。

---

# 12. v1 をデプロイする

## 12-1. この章でやること

この章では、最初のアプリバージョンである v1 を AWS にデプロイします。

## 作業場所

```text
ローカルPC
GitHub
AWS Console
ブラウザまたはcurl
```

## 対象ファイル

```text
app/main.go
```

## この章で実行する主な操作

```text
git commit
git push
GitHub Actions 確認
CodeDeploy 確認
ALB 経由でアプリ確認
```

---

## 12-2. v1 の状態を確認する

`app/main.go` で、以下になっていることを確認します。

```go
var version = "v1"
```

ローカルPCでテストします。

```bash
cd app
go test ./...
cd ..
```

---

## 12-3. main ブランチへ push する

ローカルPCで実行します。

```bash
git add .
git commit -m "deploy app v1"
git push origin main
```

---

## 12-4. 何が起きるか

`git push` を起点に、以下が自動実行されます。

```text
1. GitHub Actions が起動する
2. go test ./... が実行される
3. Go アプリが Linux 用にビルドされる
4. revision.zip が作成される
5. revision.zip が S3 にアップロードされる
6. CodeDeploy deployment が作成される
7. EC2 上の CodeDeploy Agent が artifact を取得する
8. EC2 上で appspec.yml が読まれる
9. EC2 上で deploy/scripts/*.sh が実行される
10. tutorial-app が systemd サービスとして起動する
```

---

## 12-5. 確認する場所

## GitHub Actions

```text
GitHub Repository
  → Actions
```

workflow が成功していることを確認します。

## CodeDeploy

```text
AWS Console
  → CodeDeploy
  → Applications
  → 対象Application
  → Deployments
```

deployment が成功していることを確認します。

## ALB

ローカルPCで確認します。

```bash
cd infra
terraform output -raw alb_dns_name
```

ブラウザまたは curl で確認します。

```bash
curl http://$(terraform output -raw alb_dns_name)/
curl http://$(terraform output -raw alb_dns_name)/health
curl http://$(terraform output -raw alb_dns_name)/version
```

期待結果:

```text
Hello from tutorial app v1
OK
v1
```

---

# 13. v2 にバージョンアップする

## 13-1. この章でやること

この章では、アプリを v1 から v2 に変更し、CI/CD によって自動デプロイされることを確認します。

## 作業場所

```text
ローカルPC
GitHub
AWS Console
ブラウザまたはcurl
```

## 対象ファイル

```text
app/main.go
```

---

## 13-2. アプリを v2 に変更する

`app/main.go` を編集します。

変更前:

```go
var version = "v1"
```

変更後:

```go
var version = "v2"
```

---

## 13-3. ローカルでテストする

```bash
cd app
go test ./...
cd ..
```

---

## 13-4. commit / push する

```bash
git add app/main.go
git commit -m "release app v2"
git push origin main
```

---

## 13-5. 何が起きるか

```text
1. GitHub Actions が起動する
2. テストが実行される
3. v2 のバイナリがビルドされる
4. v2 の revision.zip が S3 にアップロードされる
5. CodeDeploy が v2 を EC2 に配布する
6. ValidateService で /health が確認される
7. 成功すれば deployment が成功になる
```

---

## 13-6. 確認する場所

## GitHub Actions

```text
GitHub Repository
  → Actions
```

## CodeDeploy

```text
AWS Console
  → CodeDeploy
  → Deployments
```

## ALB 経由で確認

```bash
cd infra
curl http://$(terraform output -raw alb_dns_name)/version
```

期待結果:

```text
v2
```

---

# 14. わざと失敗させる

## 14-1. この章でやること

この章では、アプリの health check をわざと壊し、デプロイ失敗がどこで検知されるか確認します。

## 作業場所

```text
ローカルPC
GitHub
AWS Console
必要に応じてSSM Session Manager
```

## 対象ファイル

```text
app/main.go
```

---

## 14-2. 重要な注意

通常の in-place デプロイと Blue/Green デプロイでは、失敗時の影響が異なります。

```text
通常の in-place デプロイ:
  既存EC2上でアプリを入れ替える
  失敗の仕方によっては、一時的にアプリが止まる可能性がある

Blue/Green デプロイ:
  新しい環境にデプロイしてから切り替える
  health check に失敗した場合、本番切り替えを防ぎやすい
```

したがって、Blue/Green を導入する前の段階では、
「失敗しても必ず v1 が無傷で残る」とは言い切りません。

この章の目的は、まず以下を理解することです。

```text
health check が壊れる
  ↓
ValidateService が失敗する
  ↓
CodeDeploy が deployment 失敗として検知する
```

---

## 14-3. `/health` を壊す

`app/main.go` を編集します。

変更前:

```go
mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintln(w, "OK")
})
```

変更後:

```go
mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
	http.Error(w, "NG", http.StatusInternalServerError)
})
```

---

## 14-4. commit / push する

```bash
git add app/main.go
git commit -m "break health check"
git push origin main
```

---

## 14-5. 何が起きるか

```text
1. GitHub Actions が起動する
2. go test は成功する可能性がある
3. アプリがビルドされる
4. revision.zip が S3 にアップロードされる
5. CodeDeploy がデプロイを開始する
6. EC2 上で validate.sh が実行される
7. /health が HTTP 500 を返す
8. ValidateService が失敗する
9. CodeDeploy deployment が失敗になる
```

---

## 14-6. 確認する場所

## GitHub Actions

```text
GitHub Repository
  → Actions
```

## CodeDeploy

```text
AWS Console
  → CodeDeploy
  → Deployments
  → failed deployment
```

## EC2ログ

必要に応じて、SSM Session Manager で EC2 に入ります。

```text
AWS Console
  → Systems Manager
  → Session Manager
```

EC2 内で確認します。

```bash
journalctl -u tutorial-app --no-pager -n 100
cat /var/log/aws/codedeploy-agent/codedeploy-agent.log
```

---

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

