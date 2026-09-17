#Requires -Version 5.1
<#
.SYNOPSIS
    Microsoft Discovery インフラ デプロイスクリプト (Bicep クイックスタート)

.DESCRIPTION
    参考: https://learn.microsoft.com/ja-jp/azure/microsoft-discovery/quickstart-infrastructure-bicep

.EXAMPLE
    ./deploy.ps1
    既定値 (swedencentral / discoveryRG) でデプロイ

.EXAMPLE
    ./deploy.ps1 -Location eastus
    リージョンを変更 (対応: eastus/uksouth/swedencentral)

.EXAMPLE
    ./deploy.ps1 -ResourceGroup myDiscoveryRG
    リソースグループ名を変更

.EXAMPLE
    ./deploy.ps1 -DeploymentMode Production
    本番モード (現状踏襲の設定値) でデプロイ。既定はコスト最適化モード

.EXAMPLE
    ./deploy.ps1 -SkipMrgOptimize
    デプロイ後のマネージドリソースグループ最適化をスキップ

.EXAMPLE
    ./deploy.ps1 -SkipBookshelf
    Bookshelf と Knowledge 用ストレージを作らずにデプロイ (Knowledge 機能は使えません)

.EXAMPLE
    ./deploy.ps1 -SkipTools
    Microsoft.Discovery/tools を作らずにデプロイ

.EXAMPLE
    ./deploy.ps1 -BookshelfIndexSize medium
    Bookshelf の indexSize をモード既定から明示的に上書き

.EXAMPLE
    ./deploy.ps1 -RecreateSupercomputer
    未完了状態 (Succeeded 以外) の Supercomputer を削除してから作り直す

.EXAMPLE
    ./deploy.ps1 -SupercomputerName sc-retry1
    既存を残したまま別名の Supercomputer を作成
#>
[CmdletBinding()]
param(
    [string]$Location       = $(if ($env:LOCATION)        { $env:LOCATION }        else { 'swedencentral' }),
    [string]$ResourceGroup  = $(if ($env:RG)              { $env:RG }              else { 'discoveryRG' }),
    [string]$DeploymentName = $(if ($env:DEPLOYMENT_NAME) { $env:DEPLOYMENT_NAME } else { "discovery-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }),
    [string]$TemplateFile   = $(if ($env:TEMPLATE_FILE)   { $env:TEMPLATE_FILE }   else { 'main.bicep' }),

    # Entra Object IDs to grant "Microsoft Discovery Platform Administrator (Preview)"
    # on the resource group. Required for Discovery Studio (data-plane) access.
    # Defaults to the currently signed-in user so the deployer can immediately
    # create Agents / Projects in Studio after the deployment completes.
    # Override to add more users:
    #   ./deploy.ps1 -WorkspaceAdmins @('<objId1>','<objId2>')
    [string[]]$WorkspaceAdmins = @(),

    [ValidateSet('User','Group','ServicePrincipal')]
    [string]$WorkspaceAdminType = 'User',

    # コストプリセット。CostOptimized (既定) = ランニングコスト最小構成 /
    # Production = 冗長性重視の従来設定
    [ValidateSet('CostOptimized','Production')]
    [string]$DeploymentMode = $(if ($env:DEPLOYMENT_MODE) { $env:DEPLOYMENT_MODE } else { 'CostOptimized' }),

    # 指定すると、コスト最適化モードでもデプロイ後の MRG 最適化を実行しない
    [switch]$SkipMrgOptimize,

    # 指定すると Bookshelf / Knowledge 用ストレージ / Discovery ツールを作らない
    [switch]$SkipBookshelf,

    [switch]$SkipTools,

    # 空文字のときは deploymentMode のプリセット (CostOptimized: small / Production: medium)
    [ValidateSet('', 'small', 'medium', 'large')]
    [string]$BookshelfIndexSize = $(if ($env:BOOKSHELF_INDEX_SIZE) { $env:BOOKSHELF_INDEX_SIZE } else { '' }),

    # 未完了状態の Supercomputer を削除してから作り直す (破壊的操作)
    [switch]$RecreateSupercomputer,

    # 空文字のときは main.bicep の既定値 (sc-<uniqueString>)
    [string]$SupercomputerName = $(if ($env:SUPERCOMPUTER_NAME) { $env:SUPERCOMPUTER_NAME } else { '' }),

    # Microsoft.Discovery の API バージョン (main.bicep と揃える)
    [string]$DiscoveryApiVersion = '2026-06-01'
)

$ErrorActionPreference = 'Stop'

# az CLI のテレメトリ収集を無効化 (環境によってはクラッシュ回避のため必須)
$env:AZURE_CORE_COLLECT_TELEMETRY = '0'

$deployBookshelf = (-not $SkipBookshelf).ToString().ToLowerInvariant()
$deployTools     = (-not $SkipTools).ToString().ToLowerInvariant()

Write-Host '=================================================='
Write-Host ' Microsoft Discovery デプロイ'
Write-Host "   リージョン        : $Location"
Write-Host "   リソースグループ  : $ResourceGroup"
Write-Host "   デプロイ名        : $DeploymentName"
Write-Host "   テンプレート      : $TemplateFile"
Write-Host "   コストモード      : $DeploymentMode"
Write-Host "   Bookshelf         : $deployBookshelf (indexSize: $(if ($BookshelfIndexSize) { $BookshelfIndexSize } else { 'モード既定' }))"
Write-Host "   Discovery ツール  : $deployTools"
Write-Host '=================================================='

# ------------------------------------------------------------------
# 1. ログイン確認
# ------------------------------------------------------------------
Write-Host '[1/6] ログイン状態を確認...'
$subId   = az account show --query id   -o tsv
if ($LASTEXITCODE -ne 0) { throw 'az account show に失敗しました。az login を実行してください。' }
$subName = az account show --query name -o tsv
Write-Host "      サブスクリプション: $subName ($subId)"

# サインイン中のユーザーの Object ID を取得 (Discovery Studio 管理者権限付与に使用)
if ($WorkspaceAdmins.Count -eq 0) {
    $currentUserId = az ad signed-in-user show --query id -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $currentUserId) {
        $WorkspaceAdmins = @($currentUserId)
        Write-Host "      Discovery Studio 管理者 (自動): $currentUserId"
    } else {
        Write-Warning 'サインインユーザーの Object ID を取得できませんでした (Service Principal でログイン中?)。Discovery Studio 側の権限は付与されません。'
    }
} else {
    Write-Host "      Discovery Studio 管理者 (${WorkspaceAdminType}): $($WorkspaceAdmins -join ', ')"
}

# ------------------------------------------------------------------
# 2. リソースプロバイダー登録
#    ※ Discovery はプレビューのため、登録が完了していないと
#      "Cannot access Supercomputer" 等のエラーになり得る
# ------------------------------------------------------------------
Write-Host '[2/6] Microsoft.Discovery プロバイダーを登録...'
az provider register --namespace Microsoft.Discovery --only-show-errors *> $null
if ($LASTEXITCODE -ne 0) { throw 'プロバイダー登録に失敗しました。' }

# 登録完了まで待機 (最大5分)
for ($i = 1; $i -le 30; $i++) {
    $state = az provider show --namespace Microsoft.Discovery --query registrationState -o tsv
    if ($state -eq 'Registered') {
        Write-Host "      プロバイダー登録済み: $state"
        break
    }
    Write-Host "      登録待機中 ($state)... $i/30"
    Start-Sleep -Seconds 10
}

# ------------------------------------------------------------------
# 2b. Discovery 第1パーティ SP (Discovery control-plane service App) を確認
#     App ID は固定: 92c174ac-8e41-4815-a1b7-d81b19ab03ce
#     テナントに存在しない場合は作成し、Object ID を取得して Bicep に渡す
#     Docs: https://learn.microsoft.com/en-us/azure/microsoft-discovery/how-to-configure-network-security?tabs=azure-cli#verify-the-service-principal
# ------------------------------------------------------------------
Write-Host '[2b/6] Discovery control-plane サービスプリンシパルを確認...'
$discoveryAppId = '92c174ac-8e41-4815-a1b7-d81b19ab03ce'
$discoveryPrincipalId = az ad sp show --id $discoveryAppId --query id -o tsv 2>$null
if (-not $discoveryPrincipalId) {
    Write-Host "      テナントに SP が未作成。作成します..."
    az ad sp create --id $discoveryAppId --only-show-errors -o none
    if ($LASTEXITCODE -ne 0) { throw 'Discovery SP の作成に失敗しました。Application Administrator 権限が必要です。' }
    $discoveryPrincipalId = az ad sp show --id $discoveryAppId --query id -o tsv
}
if (-not $discoveryPrincipalId) { throw 'Discovery SP の Object ID を解決できませんでした。' }
Write-Host "      Discovery SP Object ID: $discoveryPrincipalId"

# ------------------------------------------------------------------
# 3. リソースグループ作成 (べき等)
# ------------------------------------------------------------------
Write-Host '[3/6] リソースグループを作成...'
az group create --name $ResourceGroup --location $Location --only-show-errors -o none
if ($LASTEXITCODE -ne 0) { throw "リソースグループの作成に失敗しました: $ResourceGroup" }
Write-Host "      OK: $ResourceGroup ($Location)"

# ------------------------------------------------------------------
# 3b. 既存 Supercomputer の健全性チェック
#     Microsoft.Discovery/supercomputers は MOBO リソースで、内部 AKS の
#     PodCidr / ServiceCidr / DnsServiceIp を Properties.InternalMetadata に
#     イミュータブル値として記録する。作成が途中で失敗した Supercomputer は
#     この値が null のまま残り、以降の再デプロイが必ず次のエラーになる:
#       Immutable property validation failed:
#       Properties.InternalMetadata.PodCidr updated from null to "10.244.0.0/16"
#     更新では復旧できないため、削除して作り直すしかない。
# ------------------------------------------------------------------
Write-Host '[3b/6] 既存 Supercomputer の状態を確認...'
$existingScs = @(az resource list -g $ResourceGroup `
    --resource-type 'Microsoft.Discovery/supercomputers' --query '[].name' -o tsv 2>$null)
$brokenScs = @()
foreach ($scName in $existingScs) {
    if (-not $scName) { continue }
    $scUrl = "https://management.azure.com/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.Discovery/supercomputers/${scName}?api-version=$DiscoveryApiVersion"
    $scState = az rest --method get --url $scUrl --query 'properties.provisioningState' -o tsv 2>$null
    if (-not $scState) { $scState = 'Unknown' }
    Write-Host "      ${scName}: $scState"
    if ($scState -ne 'Succeeded') { $brokenScs += $scName }
}

if ($brokenScs.Count -eq 0) {
    Write-Host '      問題なし'
} elseif ($RecreateSupercomputer) {
    foreach ($sc in $brokenScs) {
        Write-Host "      削除中: $sc (NodePool / moboBroker も連鎖削除されます)"
        az resource delete -g $ResourceGroup -n $sc `
            --resource-type 'Microsoft.Discovery/supercomputers' `
            --api-version $DiscoveryApiVersion -o none
        if ($LASTEXITCODE -ne 0) {
            throw "$sc の削除に失敗しました。Workspace が supercomputerIds で参照している場合は先に Workspace を削除してください: az resource delete -g $ResourceGroup -n <workspaceName> --resource-type Microsoft.Discovery/workspaces --api-version $DiscoveryApiVersion"
        }
    }
    Write-Host '      削除完了。デプロイで作り直します。'
} else {
    Write-Host ''
    Write-Host "      ⚠️ Succeeded になっていない Supercomputer を検出: $($brokenScs -join ', ')"
    Write-Host '         この状態のまま再デプロイすると InternalMetadata のイミュータブル検証で失敗します。'
    Write-Host ''
    Write-Host '      対応方法 (いずれか):'
    Write-Host '        a) 自動で削除して作り直す: ./deploy.ps1 -RecreateSupercomputer'
    Write-Host "        b) 手動で削除: az resource delete -g $ResourceGroup -n $($brokenScs[0]) --resource-type Microsoft.Discovery/supercomputers --api-version $DiscoveryApiVersion"
    Write-Host '        c) 別名で作る: ./deploy.ps1 -SupercomputerName sc-retry1'
    throw '未完了状態の Supercomputer があるためデプロイを中止しました。'
}

# ------------------------------------------------------------------
# 4. Bicep テンプレートの検証
# ------------------------------------------------------------------
Write-Host '[4/6] テンプレートを検証 (what-if 省略, validate のみ)...'
# 配列パラメータは JSON リテラル ["id1","id2"] 形式で渡す (PS 5.1 互換)
# ※ PowerShell → az.exe (Python launcher) はダブルクォートを剥がすため
#   バックスラッシュエスケープ (\") が必要
if ($WorkspaceAdmins.Count -gt 0) {
    $adminsJson = '[' + (($WorkspaceAdmins | ForEach-Object { '\"' + $_ + '\"' }) -join ',') + ']'
} else {
    $adminsJson = '[]'
}

$templateParams = @(
    "location=$Location"
    "deploymentMode=$DeploymentMode"
    "deployBookshelf=$deployBookshelf"
    "deployTools=$deployTools"
    "discoveryControlPlanePrincipalId=$discoveryPrincipalId"
    "workspaceAdminPrincipalIds=$adminsJson"
    "workspaceAdminPrincipalType=$WorkspaceAdminType"
)
if ($BookshelfIndexSize) {
    $templateParams += "bookshelfIndexSize=$BookshelfIndexSize"
}
if ($SupercomputerName) {
    $templateParams += "supercomputerName=$SupercomputerName"
}

az deployment group validate `
    --resource-group $ResourceGroup `
    --template-file $TemplateFile `
    --parameters $templateParams `
    --only-show-errors -o none
if ($LASTEXITCODE -ne 0) { throw 'テンプレートの検証に失敗しました。' }
Write-Host '      検証 OK'

# ------------------------------------------------------------------
# 5. デプロイ実行
#    ※ main.bicep には subscription() スコープのモジュールが含まれる
#      (カスタムロール作成 + Discovery SP へのロール割り当て)。
#      実行者は Subscription 上で Owner または User Access Administrator
#      権限を持つ必要があります。
# ------------------------------------------------------------------
Write-Host '[5/6] デプロイ実行 (スパコン作成に20分以上かかる場合があります)...'
$deployOutput = az deployment group create `
    --resource-group $ResourceGroup `
    --name $DeploymentName `
    --template-file $TemplateFile `
    --parameters $templateParams `
    --query "{state:properties.provisioningState, ws:properties.outputs.workspaceId.value, mode:properties.outputs.deploymentModeApplied.value, bookshelf:properties.outputs.bookshelfEndpoint.value, tools:properties.outputs.toolNames.value}" `
    -o json 2>&1
$deployExit = $LASTEXITCODE
$deployOutput | ForEach-Object { Write-Host $_ }

if ($deployExit -ne 0) {
    if (($deployOutput -join "`n") -match 'InternalMetadata') {
        Write-Host ''
        Write-Host '--------------------------------------------------'
        Write-Host ' 検出: Supercomputer の InternalMetadata イミュータブル検証エラー'
        Write-Host '--------------------------------------------------'
        Write-Host ' 既存の Supercomputer は PodCidr / ServiceCidr / DnsServiceIp が null のまま'
        Write-Host ' 登録されており、Discovery RP が既定値を書き込もうとして拒否されています。'
        Write-Host ' この状態は更新では直せません。削除して作り直してください:'
        Write-Host '   ./deploy.ps1 -RecreateSupercomputer'
        Write-Host ' 既存を残したい場合は別名で作成してください:'
        Write-Host '   ./deploy.ps1 -SupercomputerName sc-retry1'
        Write-Host '--------------------------------------------------'
    }
    throw 'デプロイに失敗しました。'
}

# ------------------------------------------------------------------
# 6. マネージドリソースグループ (MRG) のコスト最適化
#    Discovery が自動生成する AKS / Container Apps / Cosmos DB などは
#    Bicep から制御できないため、デプロイ後にスクリプトで最適化する。
#    ベストエフォート方式のため、一部が失敗しても全体は継続する。
# ------------------------------------------------------------------
if ($DeploymentMode -eq 'CostOptimized' -and -not $SkipMrgOptimize) {
    Write-Host '[6/6] マネージドリソースグループのコスト最適化...'
    $optimizeScript = Join-Path $PSScriptRoot 'optimize-mrg.ps1'
    if (Test-Path $optimizeScript) {
        # 最適化の失敗でデプロイ全体を失敗扱いにしない
        try {
            & $optimizeScript -Apply -ResourceGroup $ResourceGroup
        } catch {
            Write-Warning "MRG 最適化中にエラーが発生しましたが処理を継続します: $_"
        }
    } else {
        Write-Host '      optimize-mrg.ps1 が見つからないためスキップします。'
    }
} else {
    Write-Host "[6/6] マネージドリソースグループの最適化はスキップします (mode=$DeploymentMode)。"
}

Write-Host '=================================================='
Write-Host ' 完了。各リソースの状態は以下で確認できます:'
Write-Host "   az resource list -g $ResourceGroup --query `"[?contains(type,'Microsoft.Discovery')].{name:name,type:type}`" -o table"
Write-Host '=================================================='
