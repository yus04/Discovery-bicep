# Microsoft Discovery デプロイ ハマりポイントまとめ

Bicep で Microsoft Discovery 基盤を `uksouth` / `discoveryRG` にデプロイしたときに踏んだ罠と解決策のメモ。

## 環境メモ

| 項目 | 値 |
|---|---|
| Subscription | `<YOUR_SUBSCRIPTION_ID>` |
| Tenant | `<YOUR_TENANT_ID>`（例: 法人テナント） |
| Resource Group | `discoveryRG` |
| Region | `uksouth`（許可: eastus / swedencentral / uksouth） |
| RP / API | `Microsoft.Discovery` / `2026-06-01`（Preview） |
| リソース接尾辞 | `lbcjdf3gsd3f6` |

---

## ① moboBroker は直接削除できない

- **症状:** `microsoft.resources/moboBrokers` を消そうとすると `UnauthorizedMoboBrokerResourceModification` エラー。
- **原因:** moboBroker は **MOBO（Managed On-Behalf-Of）** リソースで、Discovery RP が所有・管理している。ユーザーが直接消せない。
- **解決:** 親の **supercomputer（または workspace）を削除するとカスケードで消える**。個別削除は不可。RG ごと消すのが手っ取り早い。

---

## ② V2 project は chatModelDeployment が Succeeded になってから作る必要がある

- **症状:** 初回デプロイで project 作成が失敗。
  ```
  Cannot create a V2 project: no ChatModelDeployment in Succeeded state found in
  workspace 'ws-lbcjdf3gsd3f6'. Create a ChatModelDeployment and ensure it reaches
  Succeeded state before creating a project.
  ```
- **原因:** project リソースが workspace と storageContainer にしか依存しておらず、ARM が chatModelDeployment の完了を待たずに**並列で project を作りにいった**（レースコンディション）。
- **解決:** project リソースに **明示的な `dependsOn` を追加**して順序を強制。
  ```bicep
  resource project 'Microsoft.Discovery/workspaces/projects@2026-06-01' = {
    parent: workspace
    name: projectName
    location: location
    dependsOn: [
      chatModelDeployment   // ← これが重要！Succeeded を待ってから作る
    ]
    properties: {
      storageContainerIds: [
        discoveryStorageContainer.id
      ]
    }
  }
  ```

---

## ③ Discovery Studio はテナント単位でフィルタする（← 一番ハマった）

- **症状:** ARM 上では workspace も project も全部 `Succeeded` なのに、**Discovery Studio の一覧が空っぽ**（「No projects created yet」→ Workspaces 一覧まで空）。
- **原因:** Studio のログインセッションが**別テナントを見ていた**。Studio はログイン中のテナント＆アクセス可能なサブスクで一覧をフィルタするため、ARM に実体があってもテナントが違うと表示されない。
- **解決:** **Studio 右上のアバターからテナントを切り替える**（リソースを作成した正しいテナントを選ぶ）。切り替えた瞬間に workspace / project が一覧に出てきた。

### Studio 画面でのテナント確認手順

1. Studio（VS Code ベース UI）の**右上のアカウントアバター**をクリック。
2. 表示されるメニューで、**今ログインしているアカウントとテナント（ディレクトリ）**を確認する。
   - 期待値: リソースを作成したアカウント / テナント（`az account show` で確認できる `tenantId`）。
3. 違うテナントが選ばれていたら、**テナント切り替え（Switch directory / Switch tenant）**で正しいテナントを選ぶ。
4. 切り替え後に **Workspaces 一覧で「Refresh」**を押すと、ARM 上の workspace / project が表示される。
5. それでも出ない場合は、az CLI 側のテナントと突き合わせて一致しているか確認:
   ```bash
   az account show --query "{user:user.name, tenantId:tenantId}" -o json
   ```
   ここで出る `tenantId` と Studio のテナントが一致していることが条件。

- **小ワザ:** workspace の ARM プロパティに **Studio 直リンク**が入っているので、一覧で迷子になったらこれを直接開けばOK。
  ```
  workspaceUiUri: https://studio.discovery.microsoft.com/workspaces/ws-lbcjdf3gsd3f6
  ```

---

## ④ 再デプロイが `Immutable property validation failed: Properties.InternalMetadata.PodCidr` で失敗する

- **症状:** 2 回目以降のデプロイが `DeploymentFailed` → `BadRequest / Resource payload validation failed` で落ちる。

  ```json
  {"code":"BadRequest","message":"Validation failed for  with message Immutable property validation failed: Properties.InternalMetadata.PodCidr updated from null to \"10.244.0.0/16\""}
  {"code":"BadRequest","message":"Validation failed for  with message Immutable property validation failed: Properties.InternalMetadata.ServiceCidr updated from null to \"10.30.0.0/16\""}
  {"code":"BadRequest","message":"Validation failed for  with message Immutable property validation failed: Properties.InternalMetadata.DnsServiceIp updated from null to \"10.30.0.10\""}
  ```

- **対象リソース:** `Microsoft.Discovery/supercomputers`。
  `PodCidr` / `ServiceCidr` / `DnsServiceIp` は内部 AKS のネットワーク設定で、
  [ARM リファレンス](https://learn.microsoft.com/azure/templates/microsoft.discovery/supercomputers)
  に公開プロパティとして存在しない **RP 内部の `InternalMetadata`**。Bicep からは指定も修正もできない。
  （`10.244.0.0/16` は AKS 既定の Pod CIDR、`10.30.0.0/16` は VNet `10.0.0.0/16` と重複しないよう RP が選んだ Service CIDR。
  つまりテンプレートのアドレス設計ミスではない。）

- **原因:** 既存の Supercomputer レコードの `InternalMetadata` が **null のまま登録されている**のに、
  現在の Discovery RP は PUT のたびにこの値を書き込もうとする。RP 自身がこの 3 項目をイミュータブル扱いしているため
  `null → 値` の遷移が拒否され、**同名の Supercomputer に対する以降の更新がすべて失敗する**。
  `InternalMetadata` が null になるのは主に次のケース:
  1. 初回デプロイが途中で失敗し、Supercomputer が `Failed` / `Canceled` のまま残っている（＝一番多い）
  2. 古い API バージョン（`2026-02-01-preview` など）で作成され、当時は `InternalMetadata` が記録されていなかった

- **解決:** 更新では直せない。**Supercomputer を削除して作り直す**しかない。

  ```bash
  # a) スクリプトに任せる (未完了状態の Supercomputer を検出して削除 → 再作成)
  RECREATE_SUPERCOMPUTER=1 ./deploy.sh
  # PowerShell: ./deploy.ps1 -RecreateSupercomputer

  # b) 手動で削除 (NodePool / moboBroker も連鎖削除される)
  az resource delete -g <RG> -n <supercomputerName> \
    --resource-type Microsoft.Discovery/supercomputers --api-version 2026-06-01

  # c) 既存を残したまま別名で作り直す
  SUPERCOMPUTER_NAME=sc-retry1 ./deploy.sh
  # PowerShell: ./deploy.ps1 -SupercomputerName sc-retry1
  ```

  b) が `Conflict` で失敗する場合は、Workspace が `supercomputerIds` で参照しているので先に Workspace を削除する。
  それも面倒なら RG ごと消すのが早い（①参照）。

- **予防:** `deploy.sh` / `deploy.ps1` は手順 `[3b/6]` で既存 Supercomputer の `provisioningState` を確認し、
  `Succeeded` でないものがあればデプロイ前に中止して対処方法を表示する。
- **補足:** `optimize-mrg.sh --apply` は MRG 内の AKS / Container Apps を直接変更する。Discovery の再プロビジョニングと
  競合している疑いがあるときは `SKIP_MRG_OPTIMIZE=1 ./deploy.sh` で切り分ける。

---

## その他メモ

- **BCP081 警告:** Bicep に Discovery の型定義が無いため出るが**無害**（Preview RP のため）。
- **`DiscoveryEnabled` の機能登録:** 現行の Discovery RP はこの機能の登録をサポートしないため、スクリプトは `Microsoft.Discovery` プロバイダー登録だけを実行する。
- **Bookshelf のモデルクォータ不足:** `text-embedding-3-small` / `gpt-5-mini` で `AvailableCapacity: 1000, RequiredCapacity: 2000` が出る場合、この値は **1 単位 = 1,000 TPM** の容量単位。つまり利用可能 1,000,000 TPM に対して 2,000,000 TPM が必要。対象リージョンの **GlobalStandard** クォータ増枠を申請する。`Standard` や他リージョンの空きは流用されない。確認は `az cognitiveservices usage list -l swedencentral`。
- **Bookshelf の SearchSubnetId:** `bookshelfSearchSubnet` は `Microsoft.App/environments` への委任が必須。検索サブネットとプライベートエンドポイント用サブネットは分ける。
- **ツールの `infra_node` エラー:** `definitionContent` に `infra[]` を定義し、`actions[]` の各要素に `infra_node` で `infra[].name` を指定する。`actions[]` ごとに必須。
- **Azure CLI クラッシュ対策:** コマンド前に `export AZURE_CORE_COLLECT_TELEMETRY=0` を付ける。
- **Preview RP の確認:** Discovery は Preview なので `az rest` で直接 RP API を叩くのが確実。デプロイの spinner を眺めるより `az rest` の status 確認のほうが情報量が多い。
- **Discovery Studio の中身:** VS Code（VS Code for the Web 系）ベースの UI。

---

## デプロイ済みリソース一覧

| リソース | 名前 | 状態 |
|---|---|---|
| supercomputer | `sc-lbcjdf3gsd3f6` | ✅ Succeeded |
| nodePool | `nodepool1` | ✅ Succeeded |
| workspace | `ws-lbcjdf3gsd3f6` | ✅ Succeeded |
| chatModelDeployment | `gpt-5-2`（gpt-5.2 / OpenAI） | ✅ Succeeded |
| storageContainer | `stc-lbcjdf3gsd3f6` | ✅ Succeeded |
| project | `prj-lbcjdf3gsd3f6` | ✅ Succeeded |
