# Microsoft Discovery インフラ 導入手順書

Bicep を使って Microsoft Discovery のインフラ一式を Azure にデプロイするための手順書です。
公式クイックスタート（[Bicep を使用してインフラストラクチャをデプロイする](https://learn.microsoft.com/ja-jp/azure/microsoft-discovery/quickstart-infrastructure-bicep)）をベースに、実際の導入で **詰まりやすいポイントと回避策** をまとめています。

> ⚠️ Microsoft Discovery は **プレビュー** サービスです。API バージョン・対応リージョン・挙動が予告なく変わる可能性があります。

---

## 1. 構成されるリソース

`main.bicep` を 1 回デプロイすると、以下が作成されます。

| カテゴリ     | リソース                               | 役割                                                                             |
| ------------ | -------------------------------------- | -------------------------------------------------------------------------------- |
| ネットワーク | 仮想ネットワーク + 6 サブネット        | スパコン/ワークスペース/エージェント/プライベートエンドポイント用                |
| ID           | ユーザー割り当てマネージド ID (UAMI)   | 各 Discovery リソースの実行 ID                                                   |
| ストレージ   | ストレージアカウント + Blob コンテナー | Discovery の出力保存先                                                           |
| Discovery    | Supercomputer（スパコン）              | 計算基盤（内部で AKS を構築）                                                    |
| Discovery    | Node Pool                              | スパコンのノードプール                                                           |
| Discovery    | Workspace                              | Discovery のワークスペース                                                       |
| Discovery    | Chat Model Deployment                  | チャットモデル（gpt-5.4 など）                                                   |
| Discovery    | Storage Container                      | Discovery 用ストレージ参照                                                       |
| Discovery    | Project                                | ワークスペース配下のプロジェクト                                                 |
| RBAC (UAMI)  | 3 つのロール割り当て                   | UAMI へ Storage Blob Data Contributor / Discovery Platform Contributor / AcrPull |
| RBAC (ユーザー) | Discovery Platform Administrator     | 実行ユーザー (または指定した Object ID) にワークスペースのデータプレーン権限を付与。**これがないと Discovery Studio 上で「Access denied」になり Agent 作成などができません** |
| RBAC (サブスク) | NSP Perimeter Joiner + Reader        | Discovery ファーストパーティ SP にサブスクリプションスコープで自動付与 (NSP 構成のため)                     |

### `main.bicep` の主なパラメーター

本テンプレートは [Azure Quickstart Templates の `discovery-infra-deployment`](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.discovery/discovery-infra-deployment) を正としており、それに加えて RBAC 自動付与の独自拡張を持ちます。

| パラメーター | 既定値 | 説明 |
| --- | --- | --- |
| `deploymentMode` | `CostOptimized` | **コストモード**。`CostOptimized` (既定) / `Production` の 2 つのパラメーターセットを一括切替。詳細は [1-1. コストモード](#1-1-コストモードdeploymentmode) |
| `location` | `swedencentral` | デプロイ先リージョン (`eastus` / `swedencentral` / `uksouth`) |
| `vnetName` | `discovery-vnet` | 仮想ネットワーク名 (2-64 文字) |
| `storageAccountSku` | `''` (モード既定) | ストレージの冗長性。`Standard_LRS` / `Standard_ZRS` / `Standard_GRS` / `Standard_GZRS` / `Standard_RAGRS` / `Standard_RAGZRS`。空文字のときはモードの既定値 |
| `storageAccessTier` | `''` (モード既定) | ストレージのアクセス層 (`Hot` / `Cool`)。空文字のときはモードの既定値 |
| `nodePoolVmSize` / `nodePoolMaxNodeCount` / `nodePoolMinNodeCount` / `nodePoolScaleSetPriority` / `nodePoolOsDiskSizeGb` | `''` / `-1` (モード既定) | ノードプールの VM サイズ・最大/最小ノード数・優先度・OS ディスクサイズ。空文字または `-1` のときはモードの既定値 |
| `supercomputerSystemSku` | `''` (モード既定) | スパコンが内部に作る AKS システムノードプールの VM SKU (`Standard_D4s_v4` / `v5` / `v6`) |
| `chatModelName` / `chatModelDeploymentName` | `gpt-5.4` / `gpt-5-4` | デプロイするチャットモデルとそのリソース名 |
| `enableGhcpAiFeatures` | `true` | Workspace の `discovery.workbench.enableGhcpAiFeatures` タグ。GitHub Copilot / AI 機能の有効化 |
| `enableExtensions` | `true` | Workspace の `discovery.workbench.enableExtensions` タグ。VS Code 拡張機能マーケットプレースの有効化 |
| `networkIsolation` | `true` | Workspace の `NetworkIsolation` タグ |
| `discoveryControlPlanePrincipalId` | (必須) | Discovery ファーストパーティ SP の **Object ID**。独自拡張 (NSP ロール付与用)。`deploy.ps1` / `deploy.sh` が自動解決 |
| `workspaceAdminPrincipalIds` | `[]` | Discovery Platform Administrator を付与する Entra Object ID の配列。独自拡張 |

> ⚠️ **`networkIsolation`**: 既定は `true` ですが、Discovery Studio のワークベンチは現時点で `false` のときのみ接続できます。パブリックプレビューのワークベンチにアクセスしたい場合は `-Parameters networkIsolation=false` を指定してください。

> 📌 **ストレージのネットワーク設定**: `networkAcls.defaultAction` は意図的に `Allow` です。`Microsoft.Discovery` コントロールプレーンが Azure Storage の信頼されたサービスバイパス一覧に未対応で、`Deny` にすると Discovery リソースのプロビジョニングが失敗するためです。デプロイした 5 サブネット (privateEndpointSubnet 以外) の `virtualNetworkRules` は事前設定済みで、Discovery が対応次第 `Deny` に切り替えられます。

---

## 1-1. コストモード（`deploymentMode`）

本テンプレートは **変数 1 つ (`deploymentMode`) を変えるだけ** で、コストに関わるパラメーター群をまとめて切り替えられます。既定は **コスト最適化モード (`CostOptimized`)** です。

| モード | 想定用途 |
| --- | --- |
| `CostOptimized` (**既定**) | PoC / 検証 / デモ。使っていない時間帯のランニングコストを最小化 |
| `Production` | 本番想定。可用性・冗長性・スループットを優先した従来どおりの設定値 |

### モードごとのパラメーターセット

`main.bicep` の `modePresets` 変数が実体です。

| 設定項目 | `CostOptimized` | `Production` | コストへの効き方 |
| --- | --- | --- | --- |
| `nodePoolMinNodeCount` (ノードプール最小ノード数) | `0` | `0` | 未使用時はノード 0 台までスケールイン (ゼロスケール) |
| `nodePoolMaxNodeCount` (最大ノード数) | `1` | `3` | 同時に起動しうる VM 台数の上限 = コスト上限 |
| `nodePoolScaleSetPriority` (VMSS 優先度) | `Spot` | `Regular` | Spot は従量課金比で最大 8〜9 割引 (退避あり) |
| `nodePoolOsDiskSizeGb` (OS ディスク) | `64` | `120` | ノード 1 台あたりのマネージドディスク料金を削減 |
| `nodePoolVmSize` | `Standard_D4s_v6` | `Standard_D4s_v6` | 実処理に必要な最小サイズ。用途に応じて個別上書き可 |
| `supercomputerSystemSku` (AKS システムノードプール SKU) | `Standard_D4s_v6` | `Standard_D4s_v6` | Discovery が許可する SKU は `Standard_D4s_v4/v5/v6` の 3 つのみ (いずれも 4 vCPU) |
| `storageAccountSku` (ストレージ冗長性) | `Standard_LRS` | `Standard_GRS` | LRS は GRS の約半額 (地理冗長なし) |
| `storageAccessTier` (アクセス層) | `Cool` | `Hot` | 保存容量単価が下がる (読み書きトランザクション単価は上がる) |

### モードの切り替え方

```bash
# コスト最適化モード (既定) — 何も指定しなければこちら
./deploy.sh

# 本番モードへ切り替え
DEPLOYMENT_MODE=Production ./deploy.sh
```

```powershell
# コスト最適化モード (既定)
./deploy.ps1

# 本番モードへ切り替え
./deploy.ps1 -DeploymentMode Production
```

```bash
# az CLI を直接使う場合
az deployment group create -g discoveryRG --template-file main.bicep \
  --parameters deploymentMode=Production
```

デプロイ結果には適用されたモードと実効値が出力されます (`deploymentModeApplied` / `effectiveCostSettings`)。

```bash
az deployment group show -g discoveryRG -n <デプロイ名> \
  --query "properties.outputs.effectiveCostSettings.value" -o json
```

### 個別のパラメーター上書き

モードはあくまで既定値の束です。個別のパラメーターを明示的に渡すと、そのパラメーターだけモード値より優先されます (文字列は空文字 `''`、数値は `-1` が「モード既定を使う」の意味)。

```bash
# コスト最適化モードのまま、ノードプールだけ Regular 優先度に戻す
az deployment group create -g discoveryRG --template-file main.bicep \
  --parameters deploymentMode=CostOptimized nodePoolScaleSetPriority=Regular
```

> ⚠️ `Spot` ノードは Azure 側の都合で **退避 (eviction)** される可能性があります。長時間の計算ジョブを走らせる場合は `nodePoolScaleSetPriority=Regular` を指定するか `Production` モードを使ってください。
>
> ⚠️ モードを変えて再デプロイする際、`nodePoolVmSize` / `scaleSetPriority` / `osDiskSizeGb` / `systemSku` / ストレージ冗長性は **作成時のみ指定可能 (immutable)** なプロパティです。既存環境で値を変えたい場合は該当リソース (ノードプール / スパコン / ストレージ) の作り直しが必要です。

### コスト最適化モードで変更される項目 (一覧)

`CostOptimized` を選んだときにどのリソースの何が変わるかの一覧です。**フェーズ 1** は Bicep デプロイ時、**フェーズ 2** はデプロイ後に `optimize-mrg` スクリプトが自動実行します。

#### フェーズ 1: Bicep で制御する (自分のリソースグループ)

| リソース | 変更項目 | `CostOptimized` | `Production` |
| --- | --- | --- | --- |
| Node Pool | 最小ノード数 | `0` (ゼロスケール) | `0` |
| Node Pool | 最大ノード数 | `1` | `3` |
| Node Pool | VMSS 優先度 | `Spot` | `Regular` |
| Node Pool | OS ディスク | `64` GB | `120` GB |
| Node Pool | VM サイズ | `Standard_D4s_v6` | `Standard_D4s_v6` |
| Supercomputer | システムノードプール SKU | `Standard_D4s_v6` | `Standard_D4s_v6` |
| ストレージアカウント | 冗長性 | `Standard_LRS` | `Standard_GRS` |
| ストレージアカウント | アクセス層 | `Cool` | `Hot` |

#### フェーズ 2: デプロイ後スクリプトで制御する (マネージドリソースグループ `mrg-...`)

| リソース | 変更項目 | `CostOptimized` での設定 | `Production` |
| --- | --- | --- | --- |
| AKS (スパコン内部) | クラスター SKU tier | `Free` (SLA なし) | 変更しない (`Standard`) |
| AKS (スパコン内部) | システムノードプール台数 | `1` 台 (下限。0 は不可) | 変更しない |
| Container Apps | 各アプリのワークロードプロファイル | `Consumption` (従量課金) へ移動 | 変更しない |
| Container Apps | 各アプリの最小レプリカ数 | `0` (ゼロスケール) | 変更しない |
| Container Apps | Dedicated (D シリーズ) プロファイル | 未使用になったら削除 | 変更しない |
| Cosmos DB | スループット種別 | `Autoscale` へ移行 | 変更しない |
| Cosmos DB | Autoscale 最大 RU/s | `1000` (最小値) | 変更しない |
| Log Analytics | データ保持期間 | `30` 日 (最短) | 変更しない |
| Log Analytics | 日次取り込み上限 | `1` GB | 変更しない |
| ストレージアカウント (MRG 内) | 冗長性 | `Standard_LRS` | 変更しない |
| ストレージアカウント (MRG 内) | アクセス層 | `Cool` | 変更しない |
| Azure AI Search | — | **変更しない (Basic 維持)** | 変更しない |
| Private Endpoint / Private DNS / NSP | — | **変更しない** (削除すると Discovery が壊れるため) | 変更しない |
| AI Foundry / Azure OpenAI | — | 変更しない (従量課金のためアイドル時の課金なし) | 変更しない |

> ⚠️ **Cosmos DB のサーバーレス化はできません。** `EnableServerless` は**アカウント作成時のみ**指定可能で、既存アカウントへの後付けは Azure の仕様上不可能です (逆方向のみ一方向で移行可)。Discovery が作成した Cosmos DB を作り直すこともできないため、代替として Autoscale 化 + 最大 RU の引き下げを行っています。

> ⚠️ **Private Endpoint は 1 本あたり月数ドルの固定費**が発生し、既定構成では 8 本前後作成されます。これは `networkIsolation=true` の帰結なので、減らしたい場合は `networkIsolation=false` でワークスペースを作り直してください。個別削除は Discovery が動作しなくなります。

### Discovery が自動作成するマネージドリソースについて

Workspace / Supercomputer を作ると、Discovery コントロールプレーンが **管理用リソースグループ (`mrg-dwsp-*` / `mrg-dscmp-*`)** に Azure Container Apps 環境・Cosmos DB・AI Search・AKS クラスター・Log Analytics・ストレージなどを自動生成します。これらは `Microsoft.Discovery` の ARM API (`2026-06-01`) に設定項目が公開されていないため、**Bicep からは SKU やスケール設定を指定できません**。

そのため本リポジトリでは **2 フェーズ方式** を採っています。

1. **Bicep で可能な範囲を最適化** (上表フェーズ 1)
2. **デプロイ後に `optimize-mrg.sh` / `optimize-mrg.ps1` で MRG 側を最適化** (上表フェーズ 2)

`deploy.sh` / `deploy.ps1` はコスト最適化モードのときに手順 2 を自動実行します。

```bash
# デプロイ + MRG 最適化 (既定)
./deploy.sh

# MRG 最適化をスキップしてデプロイだけ行う
SKIP_MRG_OPTIMIZE=1 ./deploy.sh
```

```powershell
./deploy.ps1                     # デプロイ + MRG 最適化 (既定)
./deploy.ps1 -SkipMrgOptimize    # デプロイのみ
```

#### `optimize-mrg` スクリプトを単独で実行する

既存環境に対して後から実行することもできます。**既定はドライラン** で、何が変わるかを表示するだけです。

```bash
./optimize-mrg.sh                          # ドライラン (変更内容の確認のみ)
./optimize-mrg.sh --apply                  # 実際に適用
./optimize-mrg.sh --apply --rg discoveryRG # 対象 MRG を Discovery の RG から特定
```

```powershell
./optimize-mrg.ps1                                    # ドライラン
./optimize-mrg.ps1 -Apply                             # 実際に適用
./optimize-mrg.ps1 -Apply -ResourceGroup discoveryRG  # 対象 MRG を特定
```

スクリプトの設計方針:

| 方針 | 内容 |
| --- | --- |
| **ベストエフォート** | 個々のコマンドが失敗しても**中断せず最後まで全て実行**し、成功した範囲でコストを最適化します。Discovery 側の制約で拒否される操作があるのは想定内です |
| **冪等** | 現在値を確認し、目標値と異なる場合のみ変更します。何度再実行しても安全です |
| **ドライラン既定** | `--apply` / `-Apply` を付けたときだけ実際に変更します |
| **事前チェック** | 拒否割り当て (deny assignment) とリソースロックの有無を確認し、警告を表示します |
| **サマリー出力** | 最後に 成功 / スキップ / 失敗 の件数と、失敗した項目の一覧を表示します |
| **破壊的操作なし** | Private Endpoint / Private DNS / NSP には一切触れません |

> 💡 いずれの変更も Discovery のバージョンアップや再プロビジョニングで **元の設定に戻る可能性** があります。スクリプトは冪等なので、定期的に再実行してください。恒久的なコスト削減としては「使わないときは RG ごと削除する」(6. クリーンアップ参照) が最も確実です。

> ⚠️ MRG は Discovery が所有する領域です。手動変更は **Microsoft のサポート対象外** になり得ます。検証環境での自己責任での実施を推奨します。

---

## 2. 前提条件（デプロイ前チェックリスト）

- [ ] **Azure CLI 2.60 以降**（推奨: 最新）
  ```bash
  az version
  ```
- [ ] 対象サブスクリプションに **所有者（Owner）** ロールを持っていること
- [ ] **Microsoft Discovery の利用が承認済み** のサブスクリプションであること
- [ ] デプロイ先が **対応リージョン** であること（後述）
- [ ] 十分な **クォータ**（特に `Standard_D4s_v6` の vCPU）が確保されていること

### 対応リージョン

Microsoft Discovery のリソースは **デフォルトでネットワーク強化（Network Security Perimeter / NSP）** されます。その NSP が対応しているのは以下の **3 リージョンのみ** で、これが実質の対応リージョンになります（[公式: Network security for Microsoft Discovery](https://learn.microsoft.com/azure/microsoft-discovery/concept-network-security#limitations)）。

| リージョン     | リージョン識別子  |
| -------------- | ----------------- |
| East US        | `eastus`        |
| UK South       | `uksouth`       |
| Sweden Central | `swedencentral` |

> ⚠️ **East US 2（`eastus2`）は非対応** です。Storage Discovery（別サービス）では eastus2 が使えますが、本サービス（Microsoft Discovery）とは異なるので混同に注意。

`main.bicep` の `location` 既定値は **`swedencentral`** で、`@allowed` リストもこの 3 リージョンに限定済みです。

---

## 3. クイックスタート（最短手順）

### Bash (Linux / macOS / WSL)

```bash
# 1. ログイン & サブスクリプション選択
az login
az account set --subscription "<サブスクリプションID>"

# 2. ワンコマンドデプロイ（プロバイダー登録・RG作成・検証・デプロイを自動実行）
./deploy.sh

# リージョンやRG名を変える場合（対応リージョンは eastus / uksouth / swedencentral）
LOCATION=eastus RG=myDiscoveryRG ./deploy.sh
```

### PowerShell (Windows / クロスプラットフォーム)

```powershell
# 1. ログイン & サブスクリプション選択
az login
az account set --subscription "<サブスクリプションID>"

# 2. ワンコマンドデプロイ (既定値: swedencentral / discoveryRG / 実行ユーザーを Studio 管理者に自動指定)
./deploy.ps1

# リージョン & リソースグループを変更
./deploy.ps1 -Location uksouth -ResourceGroup discoveryRG-test

# 追加ユーザー / グループに Discovery Studio 権限を付与
./deploy.ps1 -WorkspaceAdmins @('<objId1>','<objId2>')

# セキュリティグループを管理者に指定 (Type を Group に切り替え)
./deploy.ps1 -WorkspaceAdmins @('<groupObjId>') -WorkspaceAdminType Group
```

### スクリプトの自動処理内容

どちらのスクリプトも以下を自動で行います:

1. ログイン状態の確認 (+ PowerShell 版は **サインインユーザーの Object ID を自動取得**)
2. `Microsoft.Discovery` プロバイダー & `DiscoveryEnabled` フィーチャーの登録 (登録完了まで待機)
3. Discovery ファーストパーティ SP (App ID `92c174ac-8e41-4815-a1b7-d81b19ab03ce`) の存在確認 / 自動作成
4. リソースグループ作成 (べき等)
5. Bicep テンプレートの検証
6. デプロイ実行 (**サブスクリプションスコープの RBAC も含めて完結**)

### `deploy.ps1` のオプション一覧

| パラメータ / 環境変数 | 既定値 | 説明 |
| --- | --- | --- |
| `-Location` / `LOCATION` | `swedencentral` | デプロイ先リージョン (`eastus` / `uksouth` / `swedencentral`) |
| `-ResourceGroup` / `RG` | `discoveryRG` | 作成先リソースグループ名。存在しない場合は自動作成 |
| `-DeploymentName` / `DEPLOYMENT_NAME` | `discovery-<yyyyMMdd-HHmmss>` | Azure デプロイ名 (履歴に表示される名前) |
| `-TemplateFile` / `TEMPLATE_FILE` | `main.bicep` | 使用する Bicep テンプレート |
| `-WorkspaceAdmins` | `@()` → **サインインユーザーを自動追加** | Discovery Studio (データプレーン) の管理者にする Object ID の配列 |
| `-WorkspaceAdminType` | `User` | `WorkspaceAdmins` の種別。`User` / `Group` / `ServicePrincipal` |
| `-DeploymentMode` / `DEPLOYMENT_MODE` | `CostOptimized` | コストモード。`CostOptimized` / `Production` ([1-1. コストモード](#1-1-コストモードdeploymentmode)) |
| `-SkipMrgOptimize` / `SKIP_MRG_OPTIMIZE=1` | (未指定) | コスト最適化モードでもデプロイ後の MRG 最適化スクリプトを実行しない |

> ✅ **`-WorkspaceAdmins` を省略しても、スクリプトが `az ad signed-in-user show` でサインインユーザーの Object ID を自動取得し、Discovery Platform Administrator ロールを付与します。** デプロイ直後から Discovery Studio で Agent / Project 作成が可能です。
>
> 逆にサービスプリンシパルでログインしている場合は `-WorkspaceAdmins @('<objId>')` を明示指定してください (自動取得はスキップされ、警告が出ます)。

### 同一サブスクリプション内で複数リージョンにデプロイする

`main.bicep` のサブスクリプションスコープモジュール名にはリージョンサフィックスが付いています (`discoveryControlPlaneRoles-${location}`)。そのため以下のように **既存の環境を壊さずに別リージョンへ並行デプロイ** できます:

```powershell
# 既存 (swedencentral) はそのまま
./deploy.ps1 -Location swedencentral -ResourceGroup discoveryRG-prod

# 別リージョンで検証環境を追加
./deploy.ps1 -Location uksouth -ResourceGroup discoveryRG-test
```

中のカスタムロールと RBAC は GUID ベースで冪等なので、両方のデプロイで同じ Discovery ファーストパーティ SP を共有しても衝突しません。

---
Windows User の場合、`deploy.ps1` を使ってください。Bash 版 (`deploy.sh`) では Studio 管理者ロールの自動付与機能は未実装なので、デプロイ後に手動でロール割り当てが必要です (下記 5-7 参照)。

## 4. 手動デプロイ（スクリプトを使わない場合）

```bash
# テレメトリ起因のクラッシュを避けるおまじない
export AZURE_CORE_COLLECT_TELEMETRY=0

# プロバイダー & フィーチャー登録
az feature register --namespace Microsoft.Discovery --name DiscoveryEnabled
az provider register --namespace Microsoft.Discovery
# 状態が Registered になるまで待つ
az provider show --namespace Microsoft.Discovery --query registrationState -o tsv

# リソースグループ作成
az group create --name discoveryRG --location swedencentral

# デプロイ (deploymentMode を省略するとコスト最適化モード)
az deployment group create \
  --resource-group discoveryRG \
  --name discovery-deploy \
  --template-file main.bicep \
  --parameters location=swedencentral deploymentMode=CostOptimized
```

### デプロイ状況の確認

```bash
# Discovery 系リソースの一覧と状態
az resource list -g discoveryRG \
  --query "[?contains(type,'Microsoft.Discovery')].{name:name,type:type}" -o table

# ワークスペースのプロビジョニング状態
az rest --method get \
  --url "https://management.azure.com/subscriptions/<SUB>/resourceGroups/discoveryRG/providers/Microsoft.Discovery/workspaces/<WS名>?api-version=2026-06-01" \
  --query "properties.provisioningState" -o tsv
```

---

## 5. ⚠️ 詰まりポイントと回避策（実体験ベース）

### 5-1. API バージョンは `2026-06-01` 必須

Discovery リソースは **`2026-06-01`** で動作確認しています。古い API バージョンを混在させると作成に失敗します。`main.bicep` 内の `Microsoft.Discovery/*` は全てこのバージョンに揃えてください。

### 5-2. スパコンの「Succeeded」≠ 完全な準備完了

スパコンの `provisioningState` が `Succeeded` になっても、内部の **AKS クラスター構築にさらに 20 分前後** かかることがあります。ワークスペースを続けてデプロイすると早すぎて失敗するケースがあるため、Bicep では `workspace` に `dependsOn: [nodePool]` を付けて順序を保証しています。

### 5-3. `Cannot access Supercomputer '...'` エラー

ワークスペース作成時に以下が出る場合があります。

```
Cannot access Supercomputer '.../sc-xxxx' or it does not exist
```

切り分けポイント:

- スパコン本体が `Succeeded` で **直接 GET 可能** か確認
- UAMI に **Discovery Platform Contributor** ロールが付与されているか確認
- それでも解消しない場合、**`supercomputerIds` を空 `[]` にするとワークスペース作成だけは通る** → リンク検証側の問題と切り分け可能
- 全要因（権限/ネットワーク/リージョン/プロバイダ登録）がクリーンでも解消しない場合は **プレビューのバックエンド事象** の可能性が高いため、リージョンを変えて再試行 or サポートへエスカレーション

> 💡 ヒント: リソース名は `uniqueString(resourceGroup().id)` から決まるため、**同じ RG を作り直すと同名のリソース** になります。詰まったリソースが残っている状態で再デプロイすると引きずられることがあるので、**RG ごと削除 → 作り直し** でクリーンスタートするのが確実です。

### 5-4. `joinPerimeterRule/action` 権限エラー（ネットワーク強化構成）

ネットワークセキュリティ境界（NSP）を使う構成で、Discovery コントロールプレーンが NSP の受信規則を作成できずに失敗する場合があります。その際は同梱の **`nsp-perimeter-joiner-role.json`** をカスタムロールとして作成し、Discovery のファーストパーティ SP（アプリ ID `92c174ac-8e41-4815-a1b7-d81b19ab03ce`）に割り当てます。

```bash
# カスタムロール作成
az role definition create --role-definition nsp-perimeter-joiner-role.json

# Discovery ファーストパーティ SP に割り当て
SP_OBJ=$(az ad sp show --id 92c174ac-8e41-4815-a1b7-d81b19ab03ce --query id -o tsv)
az role assignment create \
  --assignee-object-id "${SP_OBJ}" \
  --assignee-principal-type ServicePrincipal \
  --role "Discovery NSP Perimeter Joiner FDPO" \
  --scope "/subscriptions/<サブスクリプションID>"
```

### 5-5. `az` コマンドがテレメトリでクラッシュする

一部環境で `az rest` 実行時にテレメトリ収集がクラッシュ要因になります。実行前に必ず:

```bash
export AZURE_CORE_COLLECT_TELEMETRY=0
```

（`deploy.sh` では自動設定済み）

### 5-6. クォータ不足

`Standard_D4s_v6` の vCPU クォータが不足しているとノードプール作成に失敗します。事前に確認・申請してください。

```bash
az vm list-usage --location swedencentral \
  --query "[?contains(localName,'D4s_v6')]" -o table
```

また、`gpt-5.4` などのモデルデプロイ時は **Cognitive Services のクォータ** も確認します:

```bash
az cognitiveservices usage list --location swedencentral \
  --query "[?contains(name.value, 'gpt-5.4')].{name:name.value, current:currentValue, limit:limit}" -o table
```

### 5-7. Discovery Studio で「Access denied」または Agent 作成が無反応

ARM 上で **Owner** ロールを持っていても、Discovery Studio (データプレーン) は **別の RBAC モデル** で動きます。以下のようなエラーが Studio に出る場合、データプレーンロールが付与されていません:

> Access denied. Ensure you have the correct role assigned on this workspace resource in the Azure portal.

**根本原因**: Discovery ワークスペースには ARM ロールとは別に、Studio 側の操作 (Agent / Project 作成、Chat Model 呼び出しなど) を許可するデータプレーンロールが必要です。

**解決策**: `deploy.ps1` を使うと **サインインユーザーへの `Microsoft Discovery Platform Administrator (Preview)` ロール割り当てを Bicep が自動生成** します (リソースグループスコープ)。デプロイ後は Studio のブラウザタブをハードリフレッシュ (Ctrl+F5) するか、一度サインアウトしてサインインし直せばトークンが更新されて操作可能になります。

既存環境に手動で追加したい場合:

```powershell
$rg      = 'discoveryRG'
$subId   = az account show --query id -o tsv
$userId  = az ad signed-in-user show --query id -o tsv
$rgScope = "/subscriptions/$subId/resourceGroups/$rg"

az role assignment create `
  --assignee-object-id $userId `
  --assignee-principal-type User `
  --role '7a2b6e6c-472e-4b39-8878-a26eb63d75c6' ` # Microsoft Discovery Platform Administrator (Preview)
  --scope $rgScope
```

参考: Discovery 関連の主な組込みロール

| ロール名 | 用途 |
| --- | --- |
| **Microsoft Discovery Platform Administrator (Preview)** | ワークスペース全体の全操作 (推奨) |
| Microsoft Discovery Platform Contributor (Preview) | ワークスペース書き込み (限定) |
| Microsoft Discovery Platform Reader (Preview) | 読み取り専用 |
| Microsoft Discovery Project Contributor - Preview | プロジェクト単位の CRUD |
| Microsoft Discovery Chat Model Reader - Preview | Chat Model 参照 |

---

## 6. クリーンアップ

```bash
# RG ごと削除（中の Discovery リソース・管理用 RG も連動削除）
az group delete --name discoveryRG --yes --no-wait
```

> Discovery のスパコン/ワークスペースは **管理用リソースグループ（`mrg-...`）** を自動生成します。RG 削除でまとめて消えますが、稀に管理用 RG が残る場合は個別に削除してください。

---

## 7. ファイル一覧

| ファイル                           | 説明                                             |
| ---------------------------------- | ------------------------------------------------ |
| `main.bicep`                     | Discovery インフラ一式の Bicep テンプレート (Discovery Studio 権限付与含む) |
| `subscription-roles.bicep`       | サブスクリプションスコープモジュール (NSP Joiner カスタムロール作成 + Discovery SP へ割り当て) |
| `deploy.sh`                      | プロバイダー登録〜デプロイを自動化する Bash スクリプト |
| `deploy.ps1`                     | PowerShell 版デプロイスクリプト (サインインユーザーを Studio 管理者に自動指定) |
| `optimize-mrg.sh`                | デプロイ後に Discovery のマネージドリソースグループをコスト最適化する Bash スクリプト (ベストエフォート / ドライラン既定) |
| `optimize-mrg.ps1`               | PowerShell 版 MRG コスト最適化スクリプト |
| `nsp-perimeter-joiner-role.json` | (参考) NSP 構成用カスタムロール定義 JSON。通常は Bicep が自動作成するので手動使用は不要 |
| `README.md`                      | 本手順書                                         |
| `TROUBLESHOOTING.md`             | 追加のトラブルシューティングメモ                 |

---

## 8. 参考リンク

- [Microsoft Discovery ドキュメント](https://learn.microsoft.com/ja-jp/azure/microsoft-discovery/)
- [Bicep でインフラをデプロイする（クイックスタート）](https://learn.microsoft.com/ja-jp/azure/microsoft-discovery/quickstart-infrastructure-bicep)
