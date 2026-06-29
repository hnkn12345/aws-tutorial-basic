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

## 8-1. `infra/versions.tf`

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

## 8-2. `infra/variables.tf`

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
  description = "GitHub owner or organization"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
}
```

---

## 8-3. ネットワーク設計

学習用として、今回は以下の構成にします。

```text
VPC
├── Public Subnet A
│   ├── ALB
│   └── EC2
└── Public Subnet C
    ├── ALB
    └── EC2
```

本番では EC2 を Private Subnet に置く方が望ましいです。

ただし、初心者向けチュートリアルでいきなり Private Subnet + NAT Gateway + VPC Endpoint まで入れると、費用と複雑さが上がります。

そのため、この教材では以下の折衷案にします。

```text
- EC2 は Public Subnet に置く
- ただし SSH は開けない
- EC2 への HTTP 通信は ALB からのみ許可する
- EC2 に直接ブラウザアクセスさせない
```

つまり、EC2 は public IP を持つ可能性がありますが、Security Group で ALB からの通信だけを許可します。

---

## 8-4. Security Group 設計

Security Group は 2 種類作ります。

```text
ALB Security Group:
  Inbound:
    TCP 80 from 0.0.0.0/0
  Outbound:
    TCP 8080 to EC2 Security Group

EC2 Security Group:
  Inbound:
    TCP 8080 from ALB Security Group
  Outbound:
    All traffic to 0.0.0.0/0
```

SSH 22 番は開けません。

EC2 に入る必要がある場合は、SSM Session Manager を使います。

---

# 9. IAM 設計

この教材では、IAM Role を主に 4 種類使います。

## 9-1. EC2 Instance Role

EC2 が使うロールです。

目的:

```text
- SSM Session Manager を使えるようにする
- CodeDeploy Agent が動作できるようにする
- S3 からデプロイ成果物を取得できるようにする
```

## 9-2. CodeDeploy Service Role

CodeDeploy が使うロールです。

目的:

```text
- Auto Scaling Group を扱う
- Target Group を扱う
- デプロイ状態を管理する
```

## 9-3. GitHub Actions OIDC Role

GitHub Actions が使うロールです。

目的:

```text
- S3 に artifact zip をアップロードする
- CodeDeploy の create-deployment を実行する
- デプロイ結果を確認する
```

## 9-4. Terraform 実行者の権限

Terraform を実行する人、または CI は、インフラ作成に必要な権限を持ちます。

学習用では広めの権限で始めてもよいですが、実務では最小権限にします。

---

# 10. EC2 起動時に入れるもの

Launch Template の user data で、EC2 起動時に以下を入れます。

```text
- Amazon Linux 2023 の更新
- CodeDeploy Agent
- SSM Agent の起動確認
- curl などの基本ツール
```

Amazon Linux 2023 では `dnf` を使います。

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
```

---

# 11. GitHub Actions の CI/CD

## 11-1. ワークフローの流れ

`.github/workflows/ci-cd.yml` を作ります。

流れは以下です。

```text
1. ソースを checkout
2. Go をセットアップ
3. go test ./...
4. go build
5. CodeDeploy 用 zip を作る
6. OIDC で AWS Role を引き受ける
7. S3 に zip をアップロード
8. CodeDeploy create-deployment を実行
9. デプロイ完了を待つ
```

---

## 11-2. GitHub Actions 例

```yaml
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
  APP_NAME: tutorial-app

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
          go-version: "1.22"

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
          go-version: "1.22"

      - name: Build
        working-directory: app
        run: |
          GOOS=linux GOARCH=amd64 go build -o tutorial-app .

      - name: Package
        run: |
          mkdir -p package/app
          cp app/tutorial-app package/app/tutorial-app
          cp deploy/appspec.yml package/appspec.yml
          cp -r deploy/scripts package/scripts
          cd package
          zip -r ../revision.zip .

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_GITHUB_ACTIONS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Upload artifact to S3
        run: |
          aws s3 cp revision.zip \
            s3://${{ vars.ARTIFACT_BUCKET }}/revisions/${{ github.sha }}.zip

      - name: Create CodeDeploy deployment
        run: |
          DEPLOYMENT_ID=$(aws deploy create-deployment \
            --application-name ${{ vars.CODEDEPLOY_APP_NAME }} \
            --deployment-group-name ${{ vars.CODEDEPLOY_DEPLOYMENT_GROUP_NAME }} \
            --s3-location bucket=${{ vars.ARTIFACT_BUCKET }},key=revisions/${{ github.sha }}.zip,bundleType=zip \
            --query deploymentId \
            --output text)

          echo "DEPLOYMENT_ID=$DEPLOYMENT_ID" >> $GITHUB_ENV

      - name: Wait deployment
        run: |
          aws deploy wait deployment-successful \
            --deployment-id "$DEPLOYMENT_ID"
```

---

# 12. v1 をデプロイする

最初の状態では、アプリの version は `v1` です。

```go
var version = "v1"
```

`main` ブランチに push します。

```bash
git add .
git commit -m "initial v1 app"
git push origin main
```

GitHub Actions が動きます。

成功すると、以下の流れになります。

```text
go test 成功
  ↓
go build 成功
  ↓
revision.zip 作成
  ↓
S3 にアップロード
  ↓
CodeDeploy 実行
  ↓
EC2 上で tutorial-app が起動
```

ALB の DNS 名にアクセスします。

```bash
curl http://<alb-dns-name>/
curl http://<alb-dns-name>/health
curl http://<alb-dns-name>/version
```

期待結果:

```text
Hello from tutorial app v1
OK
v1
```

---

# 13. v2 にバージョンアップする

`app/main.go` を変更します。

```go
var version = "v2"
```

コミットして push します。

```bash
git add app/main.go
git commit -m "release v2"
git push origin main
```

GitHub Actions が再度動きます。

期待する流れ:

```text
go test 成功
  ↓
go build 成功
  ↓
revision.zip 作成
  ↓
S3 アップロード
  ↓
CodeDeploy 実行
  ↓
新しいアプリへ更新
```

確認します。

```bash
curl http://<alb-dns-name>/version
```

期待結果:

```text
v2
```

これで、アプリのバージョンアップを CI/CD で流せました。

---

# 14. わざと失敗させる

次に、失敗時の挙動を確認します。

`/health` を壊します。

```go
mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
	http.Error(w, "NG", http.StatusInternalServerError)
})
```

push します。

```bash
git add app/main.go
git commit -m "break health check"
git push origin main
```

この場合、CodeDeploy の `ValidateService` で失敗します。

```bash
curl -fsS http://localhost:8080/health
```

が成功しないためです。

この演習で学ぶことは以下です。

```text
- デプロイは成功して終わるとは限らない
- health check が重要
- 失敗を検知できることが重要
- 失敗時に本番影響を小さくする設計が必要
```

---

# 15. Blue/Green デプロイの説明

## 15-1. 通常デプロイの問題

EC2 上でアプリをそのまま上書きするだけだと、以下の問題があります。

```text
- デプロイ中に一時的に停止する可能性がある
- 新旧バージョンが混ざる可能性がある
- 失敗時に戻す手順が難しい
- 戻すための旧成果物が必要
```

## 15-2. Blue/Green の考え方

Blue/Green では、稼働中の環境とは別に新しい環境を用意します。

```text
Blue:
  現在の本番環境

Green:
  次バージョンを入れる環境
```

図にすると以下です。

```text
Before:

Internet
  |
  v
ALB
  |
  v
Blue EC2 Group
  |
  v
App v1


Deploying:

Internet
  |
  v
ALB
  |
  +--> Blue EC2 Group -> App v1
  |
  +--> Green EC2 Group -> App v2


After:

Internet
  |
  v
ALB
  |
  v
Green EC2 Group
  |
  v
App v2
```

---

## 15-3. Blue/Green のメリット

```text
- 新環境を事前に作れる
- 新環境で health check できる
- 問題があれば旧環境に戻せる
- 本番切り替えの時間を短くできる
- サーバーを使い回さないため、環境差分が出にくい
```

## 15-4. Blue/Green の注意点

```text
- 構成が複雑になる
- 一時的にリソースが2倍必要になる
- DB migration との相性を考える必要がある
- セッション管理を考える必要がある
- Terraform state との責務分離を考える必要がある
```

特に重要なのは、Terraform と CodeDeploy の責務です。

```text
Terraform:
  Blue/Green ができる基盤を作る

CodeDeploy:
  実際のデプロイと切り替えを行う

GitHub Actions:
  デプロイ開始を指示する
```

---

# 16. Terraform と Blue/Green の境界

Blue/Green では、デプロイのたびに新しい環境が一時的に作られることがあります。

このとき、すべてを Terraform の state に入れようとすると複雑になります。

そのため、教材では以下の考え方にします。

```text
Terraform で管理する:
  - ALB
  - Target Group
  - Auto Scaling Group の基本設定
  - CodeDeploy Application
  - CodeDeploy Deployment Group
  - IAM Role
  - S3 Bucket

Terraform で毎回管理しない:
  - 個々のデプロイ実行
  - 一時的な Green 環境
  - デプロイ履歴
```

これは逃げではありません。

むしろ、実務ではよくある責務分離です。

```text
インフラの定義:
  Terraform

リリースの実行:
  CI/CD + CodeDeploy
```

---

# 17. Web デプロイのベストプラクティス

## 17-1. EC2 直アクセスで終わらない

学習初期は EC2 に直接アクセスしてもよいですが、本番では避けます。

良い構成:

```text
Internet
  |
  v
ALB
  |
  v
EC2
```

EC2 は ALB からの通信だけを受けます。

---

## 17-2. SSH を開けない

悪い例:

```text
TCP 22 from 0.0.0.0/0
```

良い例:

```text
SSH は開けない
必要なら SSM Session Manager
```

---

## 17-3. health check を用意する

アプリには必ず health check endpoint を用意します。

```text
GET /health -> OK
```

ALB や CodeDeploy は、この endpoint を使って正常性を判断します。

---

## 17-4. テストなしでデプロイしない

悪い例:

```text
push したら即デプロイ
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

## 17-5. 成果物を保存する

デプロイするものは、zip やコンテナイメージなどの成果物として保存します。

今回の構成では S3 に保存します。

```text
S3:
  revisions/<commit-sha>.zip
```

これにより、どのコミットがどの成果物としてデプロイされたか追いやすくなります。

---

## 17-6. ロールバックを前提にする

デプロイは失敗します。

その前提で設計します。

```text
- health check
- automatic rollback
- Blue/Green
- old artifact
- deployment history
```

---

## 17-7. 認証情報を長期保存しない

GitHub Secrets に AWS の長期アクセスキーを入れる構成は避けます。

良い構成:

```text
GitHub Actions
  |
  | OIDC
  v
AWS IAM Role
```

---

## 17-8. Terraform state を Git に入れない

以下は Git に入れません。

```text
terraform.tfstate
terraform.tfstate.backup
*.tfvars
```

`.terraform.lock.hcl` は通常 Git に入れます。

---

# 18. 料金面の注意

この教材では、以下のリソースで料金が発生する可能性があります。

```text
- EC2
- EBS
- ALB
- S3
- NAT Gateway を追加した場合
- CloudWatch Logs
```

特に注意すべきなのは ALB と NAT Gateway です。

この教材では、学習初期の費用を抑えるために NAT Gateway は使いません。

学習が終わったら、必ず削除します。

```bash
cd infra
terraform destroy
```

---

# 19. クリーンアップ

学習後はリソースを削除します。

```bash
cd infra
terraform destroy
```

削除後、AWS Console で以下を確認します。

```text
- EC2 が残っていない
- Auto Scaling Group が残っていない
- Launch Template が残っていない
- ALB が残っていない
- Target Group が残っていない
- S3 に不要な artifact が残っていない
- CodeDeploy Application が残っていない
- CloudWatch Logs が不要なら削除されている
```

S3 バケットにオブジェクトが残っていると、Terraform destroy が失敗する場合があります。

その場合は、artifact を削除してから再実行します。

---

# 20. この教材で得られる理解

このチュートリアルを終えると、以下が分かります。

```text
AWS 基礎:
  - Region
  - AZ
  - VPC
  - Subnet
  - Route Table
  - Internet Gateway
  - Security Group
  - EC2
  - IAM

Web デプロイ基礎:
  - ALB
  - Target Group
  - Health Check
  - Auto Scaling Group
  - systemd
  - application artifact

Terraform:
  - provider
  - resource
  - variable
  - output
  - state
  - plan
  - apply
  - destroy

CI/CD:
  - GitHub Actions
  - test
  - build
  - package
  - OIDC
  - S3 artifact
  - CodeDeploy

Blue/Green:
  - Blue 環境
  - Green 環境
  - traffic switching
  - rollback
  - health check
```

---

# 21. 発展課題

この教材の後に学ぶとよい内容は以下です。

## 発展1: EC2 を Private Subnet に移す

本番寄りの構成では、EC2 は Private Subnet に置きます。

```text
Internet
  |
  v
ALB in Public Subnet
  |
  v
EC2 in Private Subnet
```

この場合、EC2 が外部へ出るために以下を検討します。

```text
- NAT Gateway
- VPC Endpoint
```

## 発展2: HTTPS 化する

ALB に ACM 証明書を付けます。

```text
HTTP  -> HTTPS にリダイレクト
HTTPS -> ALB -> EC2
```

## 発展3: CloudWatch Logs

アプリログを CloudWatch Logs に送ります。

```text
journalctl
  ↓
CloudWatch Agent
  ↓
CloudWatch Logs
```

## 発展4: ECS / Fargate 化する

EC2 と systemd を理解した後、コンテナ化へ進むと理解しやすいです。

```text
EC2 + systemd
  ↓
Docker
  ↓
ECR
  ↓
ECS Fargate
```

## 発展5: CodePipeline / CodeBuild

GitHub Actions の代わりに AWS ネイティブの CI/CD に寄せる場合は、以下を使います。

```text
CodePipeline
CodeBuild
CodeDeploy
```

---

# 22. この教材で避けること

## 22-1. いきなり Kubernetes に行かない

Kubernetes は強力ですが、AWS の基礎理解前に入ると抽象度が高すぎます。

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

## 22-2. いきなり ECS に行かない

ECS / Fargate は実務では有力ですが、最初の AWS 学習では、EC2 の方がオンプレ経験者には対応付けしやすいです。

## 22-3. SSH 前提にしない

SSH は便利ですが、本番運用の入口としては開けすぎに注意が必要です。

この教材では、SSH を公開しません。

## 22-4. アクセスキーを GitHub に置かない

GitHub Secrets に AWS の長期アクセスキーを置く構成は避けます。

OIDC を使います。

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
AWS では、ネットワーク、FW、LB、サーバー、デプロイ手順を
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

これにより、AWS 基礎、Terraform、CI/CD、Web デプロイのベストプラクティス、Blue/Green デプロイが一本の流れとして理解できます。
