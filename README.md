# Microsoft Discovery インフラ 導入手順書

Bicep を使って Microsoft Discovery のインフラ一式を Azure にデプロイするための手順書です。
公式クイックスタート（[Bicep を使用してインフラストラクチャをデプロイする](https://learn.microsoft.com/ja-jp/azure/microsoft-discovery/quickstart-infrastructure-bicep)）をベースに、実際の導入で **詰まりやすいポイントと回避策** をまとめています。

> ⚠️ Microsoft Discovery は **プレビュー** サービスです。API バージョン・対応リージョン・挙動が予告なく変わる可能性があります。

---

## 1. 構成されるリソース

`main.bicep` を 1 回デプロイすると、以下が作成されます。

| カテゴリ     | リソース                               | 役割                                                                             |
| ------------ | -------------------------------------- | -------------------------------------------------------------------------------- |
| ネットワーク | 仮想ネットワーク + 7 サブネット        | スパコン/ワークスペース/エージェント/プライベートエンドポイント/Bookshelf 検索用 |
| ID           | ユーザー割り当てマネージド ID (UAMI)   | 各 Discovery リソースの実行 ID                                                   |
| ID           | Bookshelf 用 UAMI                      | Knowledge Base が元資料 Blob を読むためのワークロード ID                         |
| ストレージ   | ストレージアカウント + Blob コンテナー | Discovery の出力保存先 (`discoveryoutputs`)                                      |
| ストレージ   | Knowledge 用 Blob コンテナー           | Knowledge Base にインデックスする元資料置き場 (`knowledgedocuments`)             |
| Discovery    | Supercomputer（スパコン）              | 計算基盤（内部で AKS を構築）                                                    |
| Discovery    | Node Pool                              | スパコンのノードプール                                                           |
| Discovery    | Workspace                              | Discovery のワークスペース                                                       |
| Discovery    | Chat Model Deployment                  | チャットモデル（gpt-5.4 など）                                                   |
| Discovery    | Storage Container                      | Discovery 用ストレージ参照                                                       |
| Discovery    | Project                                | ワークスペース配下のプロジェクト                                                 |
| Discovery    | **Bookshelf**                          | Knowledge Base のホスト。作成すると専用 MRG に Azure SQL / AI Search / Container Apps が自動生成される |
| Discovery    | **Knowledge 用 Storage Container / Storage Asset** | Knowledge Base 作成ウィザードで選択するデータ参照定義                |
| Discovery    | **Tools**                              | Agent 作成画面の **Tools** 欄に並ぶツール定義 (`Microsoft.Discovery/tools`)       |
| RBAC (UAMI)  | 3 つのロール割り当て                   | UAMI へ Storage Blob Data Contributor / Discovery Platform Contributor / AcrPull |
| RBAC (Bookshelf) | Storage Blob Data Contributor      | Bookshelf 用 UAMI へ。これがないとインデックス時に元資料を読めない               |
| RBAC (ユーザー) | Discovery Platform Administrator     | 実行ユーザー (または指定した Object ID) にワークスペースのデータプレーン権限を付与。**これがないと Discovery Studio 上で「Access denied」になり Agent 作成などができません** |
| RBAC (サブスク) | NSP Perimeter Joiner + Reader        | Discovery ファーストパーティ SP にサブスクリプションスコープで自動付与 (NSP 構成のため)                     |

> 💡 **Bookshelf と Tools は任意**です。`deployBookshelf=false` / `deployTools=false` (または `SKIP_BOOKSHELF=1` / `-SkipBookshelf`) でスキップできます。特に Bookshelf は本テンプレートで最も高額なオプションです ([1-2. Bookshelf と Knowledge Base](#1-2-bookshelf-と-knowledge-base) 参照)。

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
| `deployBookshelf` | `true` | Bookshelf と Knowledge 用ストレージ一式 (Blob コンテナー / Storage Container / Storage Asset / UAMI / RBAC) を作成するか |
| `bookshelfName` | `bks-<uniq>` | Bookshelf 名。データプレーンエンドポイント `https://<name>.bookshelf.discovery.azure.com` に使われる |
| `bookshelfIndexSize` | `''` (モード既定) | Bookshelf の `indexSize` タグ。`small` / `medium` / `large`。MRG の計算規模を決める最大のコスト要因 |
| `bookshelfPublicNetworkAccess` | `''` (`networkIsolation` 連動) | Bookshelf データプレーンの公開接続。空のとき `networkIsolation=true` なら `Disabled` |
| `bookshelfSearchSubnetName` / `bookshelfSearchSubnetPrefix` | `bookshelfSearchSubnet` / `10.0.7.0/24` | Bookshelf のマネージド AI Search 用サブネット。**プライベートエンドポイント用とは別のサブネットが必須** |
| `knowledgeBlobContainerName` | `knowledgedocuments` | Knowledge Base にインデックスする元資料を置く Blob コンテナー |
| `knowledgeStorageContainerName` / `knowledgeStorageAssetName` | `kstc-<uniq>` / `kasset-<uniq>` | Knowledge Base 作成ウィザードで選択する Discovery 側の参照定義 |
| `knowledgeStorageAssetPath` | `''` (= `<knowledgeBlobContainerName>/`) | ストレージアカウントルートからの相対パス。サブフォルダーも指定可 |
| `deployTools` | `true` | `Microsoft.Discovery/tools` を作成するか |
| `tools` | `[]` (= サンプル 1 件) | ツール定義の配列。詳細は [1-3. Discovery ツール](#1-3-discovery-ツール) |
| `toolEnvironmentVariables` | `{}` | 全ツールにマージする追加の環境変数 |

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
| `bookshelfIndexSize` (Bookshelf の規模) | `small` | `medium` | Bookshelf MRG の AI Search / SQL / Container Apps の計算量を決める。`small` は約 200 MB までのテキストが対象 |
| `toolMaxParallelism` (ツールの並列度ヒント) | `1` | `3` | 全ツールに `DISCOVERY_MAX_PARALLELISM` として渡る。ノードプールの最大ノード数に連動 |

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
| Bookshelf | `indexSize` タグ | `small` | `medium` |
| Bookshelf | 公開ネットワークアクセス | `networkIsolation` 連動 | `networkIsolation` 連動 |
| Tools | `DISCOVERY_MAX_PARALLELISM` | `1` | `3` |

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
| **Azure SQL (Bookshelf MRG)** | サービスレベル | `GP_S_Gen5_2` (汎用サーバーレス 2 vCore) | 変更しない |
| **Azure SQL (Bookshelf MRG)** | 自動一時停止 | `60` 分アイドルで停止 | 変更しない |
| **Azure SQL (Bookshelf MRG)** | ゾーン冗長 | 無効化 | 変更しない |
| **Azure AI Search (Bookshelf MRG)** | レプリカ数 | `1` (既定の 2 から半額化) | 変更しない |
| **Azure AI Search (Bookshelf MRG)** | パーティション数 | `1` | 変更しない |
| Azure AI Search | SKU (S1 など) | **変更しない (作成時固定で変更不可)** | 変更しない |
| Private Endpoint / Private DNS / NSP | — | **変更しない** (削除すると Discovery が壊れるため) | 変更しない |
| AI Foundry / Azure OpenAI | — | 変更しない (従量課金のためアイドル時の課金なし) | 変更しない |

> ⚠️ **Azure SQL の Hyperscale からのエディション変更は拒否されることがあります。** スクリプトはベストエフォートなので、失敗しても他の項目は継続します。

> ⚠️ **AI Search のレプリカを 1 にすると可用性ゾーン冗長と SLA を失います。** 本番用途では `Production` モードを使うか、MRG 最適化をスキップしてください。

> ⚠️ **Cosmos DB のサーバーレス化はできません。** `EnableServerless` は**アカウント作成時のみ**指定可能で、既存アカウントへの後付けは Azure の仕様上不可能です (逆方向のみ一方向で移行可)。Discovery が作成した Cosmos DB を作り直すこともできないため、代替として Autoscale 化 + 最大 RU の引き下げを行っています。

> ⚠️ **Private Endpoint は 1 本あたり月数ドルの固定費**が発生し、既定構成では 8 本前後作成されます。これは `networkIsolation=true` の帰結なので、減らしたい場合は `networkIsolation=false` でワークスペースを作り直してください。個別削除は Discovery が動作しなくなります。

### Discovery が自動作成するマネージドリソースについて

Workspace / Supercomputer / Bookshelf を作ると、Discovery コントロールプレーンが **管理用リソースグループ** に各種リソースを自動生成します。

| MRG 名の接頭辞 | 作成元 | 主に入るもの |
| --- | --- | --- |
| `mrg-dwsp-*` | Workspace | Container Apps 環境 / Cosmos DB / AI Search / Log Analytics / ストレージ |
| `mrg-dscmp-*` | Supercomputer | AKS クラスター / ストレージ |
| `mrg-dbksf-*` | **Bookshelf** | **Azure SQL (Knowledge Graph) / AI Search / Container Apps / ストレージ** |

これらは `Microsoft.Discovery` の ARM API (`2026-06-01`) に設定項目が公開されていないため、**Bicep からは SKU やスケール設定を指定できません**。

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
| **Bookshelf 対応** | `mrg-dbksf-*` も対象に含め、Azure SQL のサーバーレス化と AI Search のレプリカ削減を行います |

> 💡 いずれの変更も Discovery のバージョンアップや再プロビジョニングで **元の設定に戻る可能性** があります。スクリプトは冪等なので、定期的に再実行してください。恒久的なコスト削減としては「使わないときは RG ごと削除する」(6. クリーンアップ参照) が最も確実です。

> ⚠️ MRG は Discovery が所有する領域です。手動変更は **Microsoft のサポート対象外** になり得ます。検証環境での自己責任での実施を推奨します。

---

## 1-2. Bookshelf と Knowledge Base

### なぜ Bookshelf が必要か

**Knowledge Base は単体では存在できず、必ず Bookshelf の配下に作られます。** また Bookshelf 1 つにつき Knowledge Base は 1 つです (現時点の制限)。

```text
Bookshelf (ARM リソース / 本テンプレートが作成)
  └─ Knowledge Base (データプレーン / Discovery Studio で作成)
       └─ Storage Asset → Blob コンテナーの元資料
```

### 本テンプレートが作るもの / 作らないもの

| 項目 | 作成場所 |
| --- | --- |
| Bookshelf | ✅ Bicep (`Microsoft.Discovery/bookshelves`) |
| Bookshelf 用 UAMI | ✅ Bicep |
| UAMI への Storage Blob Data Contributor | ✅ Bicep |
| Knowledge 用 Blob コンテナー | ✅ Bicep |
| Discovery Storage Container / Storage Asset | ✅ Bicep |
| Bookshelf 用検索サブネット | ✅ Bicep |
| **元資料のアップロード** | ❌ 手動 (Azure Portal / Storage Explorer / `az storage blob upload-batch`) |
| **Knowledge Base 本体** | ❌ Discovery Studio > Resources > Knowledge |
| **Index の実行** | ❌ Discovery Studio (Knowledge Base 詳細画面の Index ボタン) |

Knowledge Base の作成と Index は **データプレーン操作** で ARM のライフサイクル外のため、Bicep では作成できません。

### デプロイ後の手順

```bash
# 1. 元資料をアップロード (対応形式: pdf / docx / pptx / xlsx / txt / html)
STG=$(az deployment group show -g discoveryRG -n <デプロイ名> \
        --query "properties.outputs.storageAccountId.value" -o tsv | awk -F/ '{print $NF}')
az storage blob upload-batch \
  --account-name "${STG}" --auth-mode login \
  --destination knowledgedocuments --source ./docs
```

2. Discovery Studio > 左メニュー **Resources** > **Knowledge**
3. **Bookshelf** ドロップダウンで本テンプレートが作った Bookshelf を選択 → **+ Create new**
4. Name / Version / Description / Copilot instruction を入力
5. **Storage Container** / **Storage Asset** / **User Assigned Identity** はすべて本テンプレートが作成済みのものを選択 (デプロイ出力の `knowledgeStorageContainerId` / `knowledgeStorageAssetId` / `bookshelfIdentityId`)
6. **Create** → 詳細画面の **Index** ボタンで Project と Node Pool を選び **Start Indexing**

### ⚠️ Index 用ノードプールについて

インデックス処理は **メモリ集約的** です。本テンプレートの既定ノードプールは `Standard_D4s_v6` (4 vCPU / 16 GB) なので、公式推奨値を満たしません。

| Index サイズ | テキスト量 | 公式推奨 SKU | メモリ |
| --- | --- | --- | --- |
| Small | 約 200 MB | `Standard_E20s_v6` | 160 GB |
| Medium | 約 500 MB | `Standard_E64s_v6` | 512 GB |
| Large | 約 1 GB | `Standard_E96s_v6` | 768 GB |

少量の検証であれば既定ノードプールでも動く可能性がありますが、失敗する場合は **Index 実行時だけ** メモリ最適化ノードプールを追加し、終わったら削除するのがコスト面で有利です。

```bash
# Index 用ノードプールを一時的に追加 (最小 0 台なので未使用時は課金されない)
az deployment group create -g discoveryRG --template-file main.bicep \
  --parameters nodePoolName=idxpool nodePoolVmSize=Standard_E20s_v6 \
               nodePoolMaxNodeCount=1 nodePoolMinNodeCount=0
```

### ⚠️ モデルのクォータ

Knowledge Base の Index と検索には、チャットモデルとは別に以下が必要です。**本テンプレートはこれらのモデルデプロイを作成しません。**

| モデル | 用途 | Bookshelf 作成時 | Index / 検索時の推奨 |
| --- | --- | --- | --- |
| `text-embedding-3-small` | Embedding | 200,000 TPM | 2,000,000 TPM |
| `GPT-5.2` | Knowledge Base 検索 | 200,000 TPM | 2,000,000 TPM |
| `GPT-5-mini` | Knowledge Base 検索 | 200,000 TPM | 10,000,000 TPM |

> 💡 TPM クォータは Index 完了後に引き下げられます。クォータの確保自体には課金は発生しませんが、他のワークロードを圧迫します。

### Bookshelf を作らないデプロイ

Knowledge 機能が不要なら、Bookshelf MRG の固定費 (Azure SQL / AI Search / Container Apps) を丸ごと回避できます。

```bash
SKIP_BOOKSHELF=1 ./deploy.sh
```

```powershell
./deploy.ps1 -SkipBookshelf
```

---

## 1-3. Discovery ツール

### Discovery Studio ではツールを「作れない」

Discovery Studio の Agent 作成画面にある **Tools** 欄は、ワークスペースにすでに存在するツールを **選択するだけ** の UI です。ツール実体は ARM リソース `Microsoft.Discovery/tools` なので、**Bicep / CLI で作成する必要があります**。作成していなければ Tools 欄は空のままです。

### ツール定義の形式

`tools` パラメーターに配列で渡します。省略するとサンプルツール (`dataset-summary`) が 1 件作られます。

| キー | 必須 | 説明 |
| --- | --- | --- |
| `name` | ✅ | ARM リソース名。`^[a-zA-Z0-9-]{3,24}$` |
| `version` | ✅ | ツール定義のバージョン文字列 |
| `definitionContent` | ✅ | `tool_id` / `name` / `description` / `actions[]` を含む JSON |
| `environmentVariables` | — | そのツール固有の環境変数 |

`actions[]` の各要素は `name` / `description` / `input_schema` (JSON Schema) / `command` / `environment_variables[]` で構成されます。`{{ 変数名 }}` で `input_schema` の入力値を参照できます。

```bicep
// 例: パラメーターファイルで自前ツールを渡す
param tools = [
  {
    name: 'md-simulation'
    version: '1.0.0'
    definitionContent: {
      tool_id: 'md-simulation'
      name: 'MolecularDynamics'
      description: '分子動力学シミュレーションを実行します。'
      actions: [
        {
          name: 'RunSimulation'
          description: '構造を /app/inputs にマウントし、/app/outputs をキャプチャしてください。'
          input_schema: {
            type: 'object'
            properties: {
              steps: { type: 'string', description: 'ステップ数' }
            }
            required: [ 'steps' ]
          }
          command: 'python3 run_md.py'
          environment_variables: [
            { name: 'STEPS', value: '{{ steps }}' }
          ]
        }
      ]
    }
  }
]
```

### 全ツールに自動注入される環境変数

ツールのコマンドがデプロイ構成に合わせて振る舞えるよう、以下を全ツールにマージします。

| 環境変数 | 値 |
| --- | --- |
| `DISCOVERY_DEPLOYMENT_MODE` | `CostOptimized` / `Production` |
| `DISCOVERY_NODE_POOL_NAME` | ノードプール名 |
| `DISCOVERY_STORAGE_CONTAINER_NAME` | Discovery Storage Container 名 |
| `DISCOVERY_MAX_PARALLELISM` | ノードプールの最大ノード数 (コストモード連動: `1` / `3`) |

`toolEnvironmentVariables` パラメーターで任意の変数を追加できます。

### コスト

**ツールリソース自体にランニングコストはありません。** ツールは定義 (JSON) に過ぎず、課金が発生するのは Agent がツールを実行してノードプールがスケールアウトしたときだけです。そのためツールは両モードとも既定でデプロイします。

作成しない場合は以下です。

```bash
SKIP_TOOLS=1 ./deploy.sh
```

```powershell
./deploy.ps1 -SkipTools
```

### 確認方法

```bash
az resource list -g discoveryRG \
  --resource-type Microsoft.Discovery/tools \
  --query "[].{name:name, state:properties.provisioningState}" -o table
```

作成後、Discovery Studio > Projects > 対象 Project > Resources > Agents > **Create new agent** > **Tools** に一覧表示されます。

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
- [ ] (Bookshelf を使う場合) **Azure SQL / AI Search / Container Apps のクォータ** が確保されていること
- [ ] (Knowledge Base を使う場合) **Embedding / GPT モデルの TPM クォータ** が確保されていること ([1-2](#1-2-bookshelf-と-knowledge-base) 参照)

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

# Bookshelf を作らない (Knowledge 機能不要 / コスト最小)
SKIP_BOOKSHELF=1 ./deploy.sh

# Discovery ツールを作らない
SKIP_TOOLS=1 ./deploy.sh

# Bookshelf の規模を明示指定
BOOKSHELF_INDEX_SIZE=medium ./deploy.sh
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

# Bookshelf / Discovery ツールを作らない
./deploy.ps1 -SkipBookshelf
./deploy.ps1 -SkipTools

# Bookshelf の規模を明示指定
./deploy.ps1 -BookshelfIndexSize medium
```

### スクリプトの自動処理内容

どちらのスクリプトも以下を自動で行います:

1. ログイン状態の確認と **サインインユーザーの Object ID 自動取得** (Discovery Studio 管理者権限の付与に使用)
2. `Microsoft.Discovery` プロバイダー & `DiscoveryEnabled` フィーチャーの登録 (登録完了まで待機)
3. Discovery ファーストパーティ SP (App ID `92c174ac-8e41-4815-a1b7-d81b19ab03ce`) の存在確認 / 自動作成
4. リソースグループ作成 (べき等)
5. Bicep テンプレートの検証
6. デプロイ実行 (**サブスクリプションスコープの RBAC、Bookshelf、Discovery ツールを含めて完結**)
7. コスト最適化モードのときは MRG のコスト最適化 (`optimize-mrg`) を実行

### デプロイスクリプトのオプション一覧

| `deploy.ps1` | `deploy.sh` (環境変数) | 既定値 | 説明 |
| --- | --- | --- | --- |
| `-Location` | `LOCATION` | `swedencentral` | デプロイ先リージョン (`eastus` / `uksouth` / `swedencentral`) |
| `-ResourceGroup` | `RG` | `discoveryRG` | 作成先リソースグループ名。存在しない場合は自動作成 |
| `-DeploymentName` | `DEPLOYMENT_NAME` | `discovery-<yyyyMMdd-HHmmss>` | Azure デプロイ名 (履歴に表示される名前) |
| `-TemplateFile` | `TEMPLATE_FILE` | `main.bicep` | 使用する Bicep テンプレート |
| `-DeploymentMode` | `DEPLOYMENT_MODE` | `CostOptimized` | コストモード。`CostOptimized` / `Production` ([1-1. コストモード](#1-1-コストモードdeploymentmode)) |
| `-WorkspaceAdmins` | (自動) | サインインユーザーを自動追加 | Discovery Studio (データプレーン) の管理者にする Object ID の配列 |
| `-WorkspaceAdminType` | (なし) | `User` | `WorkspaceAdmins` の種別。`User` / `Group` / `ServicePrincipal` |
| `-SkipMrgOptimize` | `SKIP_MRG_OPTIMIZE=1` | (未指定) | コスト最適化モードでもデプロイ後の MRG 最適化スクリプトを実行しない |
| `-SkipBookshelf` | `SKIP_BOOKSHELF=1` | (未指定) | Bookshelf と Knowledge 用ストレージ一式を作成しない ([1-2](#1-2-bookshelf-と-knowledge-base)) |
| `-SkipTools` | `SKIP_TOOLS=1` | (未指定) | `Microsoft.Discovery/tools` を作成しない ([1-3](#1-3-discovery-ツール)) |
| `-BookshelfIndexSize` | `BOOKSHELF_INDEX_SIZE` | (モード既定) | Bookshelf の規模。`small` / `medium` / `large` |

> ✅ **`-WorkspaceAdmins` を省略しても、スクリプトが `az ad signed-in-user show` でサインインユーザーの Object ID を自動取得し、Discovery Platform Administrator ロールを付与します。** デプロイ直後から Discovery Studio で Agent / Project 作成が可能です。
>
> 逆にサービスプリンシパルでログインしている場合は `-WorkspaceAdmins @('<objId>')` を明示指定してください (自動取得はスキップされ、警告が出ます)。`deploy.sh` は常にサインインユーザーを自動付与します。

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
Windows ユーザーは `deploy.ps1`、Linux / macOS / WSL ユーザーは `deploy.sh` を使ってください。どちらも Discovery SP の解決、Studio 管理者ロールの自動付与、Bookshelf / Discovery ツールのデプロイに対応しています。サービスプリンシパルでログインしている場合のみ、Studio 権限を手動で付与する必要があります (下記 5-7 参照)。

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
# discoveryControlPlanePrincipalId は必須。事前に Object ID を解決する
DISC_SP=$(az ad sp show --id 92c174ac-8e41-4815-a1b7-d81b19ab03ce --query id -o tsv)

az deployment group create \
  --resource-group discoveryRG \
  --name discovery-deploy \
  --template-file main.bicep \
  --parameters location=swedencentral deploymentMode=CostOptimized \
               discoveryControlPlanePrincipalId="${DISC_SP}"

# Bookshelf / Discovery ツールを作らない場合
az deployment group create \
  --resource-group discoveryRG \
  --name discovery-deploy \
  --template-file main.bicep \
  --parameters location=swedencentral deploymentMode=CostOptimized \
               discoveryControlPlanePrincipalId="${DISC_SP}" \
               deployBookshelf=false deployTools=false
```

### デプロイ状況の確認

```bash
# Discovery 系リソースの一覧と状態
az resource list -g discoveryRG \
  --query "[?contains(type,'Microsoft.Discovery')].{name:name,type:type}" -o table

# Bookshelf と Discovery ツールだけを抽出
az resource list -g discoveryRG \
  --query "[?type=='Microsoft.Discovery/bookshelves' || type=='Microsoft.Discovery/tools'].{name:name,type:type,state:properties.provisioningState}" \
  -o table

# ワークスペースのプロビジョニング状態
az rest --method get \
  --url "https://management.azure.com/subscriptions/<SUB>/resourceGroups/discoveryRG/providers/Microsoft.Discovery/workspaces/<WS名>?api-version=2026-06-01" \
  --query "properties.provisioningState" -o tsv

# Knowledge Base 作成ウィザードで選ぶリソースの ID を取得
az deployment group show -g discoveryRG -n <デプロイ名> \
  --query "{bookshelf:properties.outputs.bookshelfEndpoint.value, container:properties.outputs.knowledgeStorageContainerId.value, asset:properties.outputs.knowledgeStorageAssetId.value, identity:properties.outputs.bookshelfIdentityId.value}" \
  -o json
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
| `main.bicep`                     | Discovery インフラ一式の Bicep テンプレート (Studio 権限付与 / Bookshelf / Knowledge ストレージ / Discovery ツールを含む) |
| `subscription-roles.bicep`       | サブスクリプションスコープモジュール (NSP Joiner カスタムロール作成 + Discovery SP へ割り当て) |
| `deploy.sh`                      | プロバイダー登録〜デプロイを自動化する Bash スクリプト (サインインユーザーを Studio 管理者に自動指定) |
| `deploy.ps1`                     | PowerShell 版デプロイスクリプト (サインインユーザーを Studio 管理者に自動指定) |
| `optimize-mrg.sh`                | デプロイ後に Discovery のマネージドリソースグループ (Workspace / Supercomputer / Bookshelf) をコスト最適化する Bash スクリプト (ベストエフォート / ドライラン既定) |
| `optimize-mrg.ps1`               | PowerShell 版 MRG コスト最適化スクリプト |
| `nsp-perimeter-joiner-role.json` | (参考) NSP 構成用カスタムロール定義 JSON。通常は Bicep が自動作成するので手動使用は不要 |
| `resources.md`                   | デプロイされるリソース一覧と依存関係図 |
| `TROUBLESHOOTING.md`             | 実際に踏んだ罠と解決策のメモ |
| `README.md`                      | 本手順書                                         |
| `TROUBLESHOOTING.md`             | 追加のトラブルシューティングメモ                 |

---

## 8. 参考リンク

- [Microsoft Discovery ドキュメント](https://learn.microsoft.com/ja-jp/azure/microsoft-discovery/)
- [Bicep でインフラをデプロイする（クイックスタート）](https://learn.microsoft.com/ja-jp/azure/microsoft-discovery/quickstart-infrastructure-bicep)
