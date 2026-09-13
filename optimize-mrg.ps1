#Requires -Version 5.1
<#
.SYNOPSIS
    Microsoft Discovery マネージドリソースグループ (MRG) コスト最適化スクリプト

.DESCRIPTION
    Workspace / Supercomputer を作ると、Discovery のコントロールプレーンが
    管理用リソースグループ (mrg-dwsp-* / mrg-dscmp-*) に AKS / Container Apps /
    Cosmos DB / AI Search / Storage / Log Analytics などを自動生成します。
    これらは Microsoft.Discovery の ARM API に設定項目が公開されていないため
    Bicep からは制御できません。本スクリプトはデプロイ後にそれらを
    「変更できる範囲で」コスト最適化します。

    設計方針:
      * ベストエフォート。個々のコマンドが失敗しても中断せず最後まで実行します。
        (Discovery 側の制約で拒否される操作があるのは想定内のため)
      * 冪等。現在値を確認し、目標値と異なる場合のみ変更します。
        Discovery の再プロビジョニングで設定が戻るので、何度でも再実行できます。
      * 既定はドライラン。-Apply を付けたときだけ実際に変更します。
      * Private Endpoint / Private DNS / NSP には一切触れません (削除すると
        Discovery が動作しなくなるため)。

    ⚠️ MRG は Discovery が所有する領域です。手動変更は Microsoft のサポート対象外に
       なり得ます。また Discovery のバージョンアップや再プロビジョニングで設定が
       元に戻る場合があります。検証環境での自己責任の実施を推奨します。

.EXAMPLE
    ./optimize-mrg.ps1
    ドライラン (現状と変更予定を表示するのみ)

.EXAMPLE
    ./optimize-mrg.ps1 -Apply
    実際に変更を適用

.EXAMPLE
    ./optimize-mrg.ps1 -Apply -ResourceGroup discoveryRG
    Discovery リソースが入っている RG を指定して対象 MRG を特定
#>
[CmdletBinding()]
param(
    # 指定した場合のみ実際に変更を適用する (既定はドライラン)
    [switch]$Apply,

    # Discovery リソースが入っている RG。指定すると、その RG に紐づく MRG だけを対象にする
    [string]$ResourceGroup = $(if ($env:RG) { $env:RG } else { '' })
)

# 個々のコマンドが失敗してもスクリプトを継続させる (ベストエフォート方式)
$ErrorActionPreference = 'Continue'
$env:AZURE_CORE_COLLECT_TELEMETRY = '0'

# 目標値
$TargetAksTier          = 'free'            # AKS クラスター SKU
$TargetAksSystemNodes   = 1                 # AKS システムノードプールのノード数 (最小 1)
$TargetAcaMinReplicas   = 0                 # Container Apps の最小レプリカ数 (ゼロスケール)
$TargetAcaProfile       = 'Consumption'     # Container Apps のワークロードプロファイル
$TargetCosmosMaxRu      = 1000              # Cosmos DB Autoscale の最大 RU/s (最小値)
$TargetLawRetentionDays = 30                # Log Analytics 保持期間 (最短)
$TargetLawDailyQuotaGb  = 1                 # Log Analytics 日次取り込み上限
$TargetStorageSku       = 'Standard_LRS'    # ストレージ冗長性
$TargetStorageTier      = 'Cool'            # ストレージアクセス層

# 集計用
$script:OkCount     = 0
$script:SkipCount   = 0
$script:FailCount   = 0
$script:FailedItems = New-Object System.Collections.Generic.List[string]

function Write-Head($text) {
    Write-Host ''
    Write-Host '=============================================================='
    Write-Host " $text"
    Write-Host '=============================================================='
}
function Write-Sub($text)  { Write-Host ''; Write-Host "-- $text" }
function Write-Skip($text) { Write-Host "      [SKIP] $text"; $script:SkipCount++ }
function Write-Ok($text)   { Write-Host "      [OK]   $text"; $script:OkCount++ }
function Write-Fail($text) { Write-Host "      [FAIL] $text"; $script:FailCount++; $script:FailedItems.Add($text) }

# 変更コマンドを実行する共通ラッパー。
# 失敗しても例外を投げず、結果を記録して継続する。
function Invoke-Change {
    param(
        [string]$Description,
        [string[]]$AzArgs
    )
    if (-not $Apply) {
        Write-Host "      [DRY]  $Description"
        Write-Host "             `$ az $($AzArgs -join ' ')"
        $script:SkipCount++
        return
    }
    $out = & az @AzArgs 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Ok $Description
    } else {
        Write-Fail $Description
        ($out | Select-Object -First 3) | ForEach-Object { Write-Host "             $_" }
    }
}

# az の JSON 出力を安全にオブジェクト化する (失敗時は $null)
function Get-AzJson {
    param([string[]]$AzArgs)
    $raw = & az @AzArgs 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

Write-Head 'Microsoft Discovery MRG コスト最適化'
if ($Apply) {
    Write-Host '   モード: APPLY (実際に変更します)'
} else {
    Write-Host '   モード: DRY-RUN (変更内容の表示のみ。-Apply で適用)'
}

# ------------------------------------------------------------------
# 1. ログイン確認
# ------------------------------------------------------------------
$subId = az account show --query id -o tsv 2>$null
if (-not $subId) {
    Write-Error 'az account show に失敗しました。az login を実行してください。'
    exit 1
}
Write-Host "   サブスクリプション: $subId"

# ------------------------------------------------------------------
# 2. 対象 MRG の特定
#    Discovery の MRG 命名規則:
#      Workspace     : mrg-dwsp-<name>-<6桁>
#      Supercomputer : mrg-dscmp-<name>-<6桁>
#      Bookshelf     : mrg-dbksf-<name>-<6桁>
# ------------------------------------------------------------------
$mrgs = @()
if ($ResourceGroup) {
    Write-Host "   Discovery RG: $ResourceGroup に紐づく MRG を検索します"
    $discNames = az resource list -g $ResourceGroup `
        --query "[?starts_with(type,'Microsoft.Discovery/')].name" -o tsv 2>$null
    foreach ($n in $discNames) {
        if (-not $n) { continue }
        $found = az group list --query "[?contains(name, '$n')].name" -o tsv 2>$null
        foreach ($f in $found) { if ($f) { $mrgs += $f } }
    }
    $mrgs = $mrgs | Select-Object -Unique
}

if (-not $mrgs -or $mrgs.Count -eq 0) {
    $mrgs = az group list `
        --query "[?starts_with(name,'mrg-dwsp-') || starts_with(name,'mrg-dscmp-') || starts_with(name,'mrg-dbksf-')].name" `
        -o tsv 2>$null
}
$mrgs = @($mrgs | Where-Object { $_ })

if ($mrgs.Count -eq 0) {
    Write-Host '   対象の MRG が見つかりませんでした。Discovery のデプロイが完了しているか確認してください。'
    exit 0
}

Write-Host "   対象 MRG: $($mrgs.Count) 件"
$mrgs | ForEach-Object { Write-Host "     - $_" }

# ------------------------------------------------------------------
# 3. 事前チェック: 拒否割り当て (deny assignment) とリソースロック
#    これらが存在すると Owner であっても変更が拒否される。
#    見つかっても中断はせず、警告のみ出して処理を続行する。
# ------------------------------------------------------------------
Write-Head '事前チェック (拒否割り当て / ロック)'
foreach ($rg in $mrgs) {
    Write-Sub $rg
    $deny = az rest --method get `
        --url "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Authorization/denyAssignments?api-version=2022-04-01" `
        --query "value[].properties.denyAssignmentName" -o tsv 2>$null
    if ($deny) {
        Write-Host "      ⚠️ 拒否割り当てあり: $($deny -join ', ')"
        Write-Host '         Owner 権限でも一部の変更が拒否される可能性があります。'
    } else {
        Write-Host '      拒否割り当て: なし'
    }
    $locks = az lock list -g $rg --query "[].name" -o tsv 2>$null
    if ($locks) {
        Write-Host "      ⚠️ リソースロックあり: $($locks -join ', ')"
    } else {
        Write-Host '      リソースロック: なし'
    }
}

# ------------------------------------------------------------------
# 4. AKS (Supercomputer の内部クラスター)
#    - クラスター SKU tier を Free に (Standard は SLA 付きで有償)
#    - システムノードプールを 1 台に (システムプールの下限は 1。0 にはできない)
# ------------------------------------------------------------------
Write-Head 'AKS クラスター'
foreach ($rg in $mrgs) {
    $clusters = az resource list -g $rg --resource-type 'Microsoft.ContainerService/managedClusters' `
        --query "[].name" -o tsv 2>$null
    foreach ($aks in @($clusters | Where-Object { $_ })) {
        Write-Sub "$rg / $aks"

        $info = Get-AzJson @('aks', 'show', '-g', $rg, '-n', $aks, '-o', 'json')
        if (-not $info) {
            Write-Fail "AKS ${aks}: 情報取得に失敗"
            continue
        }

        $tier = $info.sku.tier
        if ($tier -and $tier.ToLower() -eq $TargetAksTier) {
            Write-Skip "AKS ${aks}: SKU tier は既に $tier"
        } else {
            Invoke-Change "AKS ${aks}: SKU tier $tier -> $TargetAksTier" `
                @('aks', 'update', '-g', $rg, '-n', $aks, '--tier', $TargetAksTier, '-o', 'none')
        }

        # システムノードプール (mode=System) を 1 台へ。
        foreach ($pool in @($info.agentPoolProfiles | Where-Object { $_.mode -eq 'System' })) {
            if ($pool.enableAutoScaling) {
                if ($pool.minCount -eq $TargetAksSystemNodes -and $pool.maxCount -eq $TargetAksSystemNodes) {
                    Write-Skip "AKS $aks/$($pool.name): オートスケール範囲は既に $TargetAksSystemNodes-$TargetAksSystemNodes"
                } else {
                    Invoke-Change "AKS $aks/$($pool.name): オートスケール範囲 $($pool.minCount)-$($pool.maxCount) -> $TargetAksSystemNodes-$TargetAksSystemNodes" `
                        @('aks', 'nodepool', 'update', '-g', $rg, '--cluster-name', $aks, '-n', $pool.name,
                          '--update-cluster-autoscaler', '--min-count', "$TargetAksSystemNodes",
                          '--max-count', "$TargetAksSystemNodes", '-o', 'none')
                }
            } else {
                if ($pool.count -eq $TargetAksSystemNodes) {
                    Write-Skip "AKS $aks/$($pool.name): ノード数は既に $($pool.count)"
                } else {
                    Invoke-Change "AKS $aks/$($pool.name): ノード数 $($pool.count) -> $TargetAksSystemNodes" `
                        @('aks', 'nodepool', 'scale', '-g', $rg, '--cluster-name', $aks, '-n', $pool.name,
                          '--node-count', "$TargetAksSystemNodes", '-o', 'none')
                }
            }
        }
    }
}

# ------------------------------------------------------------------
# 5. Azure Container Apps
#    - 各アプリを従量課金 (Consumption) プロファイルへ移し、最小レプリカを 0 に
#    - 全アプリの移行後、Dedicated (D シリーズ等) プロファイルを削除
#    ※ 環境の種類 (ワークロードプロファイル型 / Consumption 専用型) は作成時に
#      固定で後から変更できないため、Consumption プロファイルのみを残す形にする。
# ------------------------------------------------------------------
Write-Head 'Azure Container Apps'
foreach ($rg in $mrgs) {
    $envs = az resource list -g $rg --resource-type 'Microsoft.App/managedEnvironments' `
        --query "[].name" -o tsv 2>$null
    foreach ($envName in @($envs | Where-Object { $_ })) {
        Write-Sub "$rg / $envName"

        # 5-1. Consumption プロファイルが無ければ追加
        $profiles = Get-AzJson @('containerapp', 'env', 'workload-profile', 'list', '-g', $rg, '-n', $envName, '-o', 'json')
        if (-not $profiles) {
            Write-Skip "${envName}: ワークロードプロファイル情報を取得できませんでした (Consumption 専用環境の可能性)"
        } elseif (-not ($profiles | Where-Object { $_.workloadProfileType -eq 'Consumption' })) {
            Invoke-Change "${envName}: Consumption プロファイルを追加" `
                @('containerapp', 'env', 'workload-profile', 'add', '-g', $rg, '-n', $envName,
                  '--workload-profile-name', $TargetAcaProfile, '--workload-profile-type', 'Consumption', '-o', 'none')
        } else {
            Write-Skip "${envName}: Consumption プロファイルは既に存在"
        }

        # 5-2. 各アプリを Consumption + 最小レプリカ 0 へ
        $apps = Get-AzJson @('containerapp', 'list', '-g', $rg, '-o', 'json')
        $envApps = @($apps | Where-Object { $_.properties.environmentId -like "*/$envName" })
        foreach ($app in $envApps) {
            $azArgs = @('containerapp', 'update', '-g', $rg, '-n', $app.name)
            $descParts = @()
            $curProfile = $app.properties.workloadProfileName
            $curMin     = $app.properties.template.scale.minReplicas

            if ($profiles -and $curProfile -ne $TargetAcaProfile) {
                $azArgs += @('--workload-profile-name', $TargetAcaProfile)
                $shown = if ($curProfile) { $curProfile } else { '未設定' }
                $descParts += "プロファイル $shown -> $TargetAcaProfile"
            }
            if ($curMin -ne $TargetAcaMinReplicas) {
                $azArgs += @('--min-replicas', "$TargetAcaMinReplicas")
                $descParts += "最小レプリカ $curMin -> $TargetAcaMinReplicas"
            }

            if ($descParts.Count -eq 0) {
                Write-Skip "アプリ $($app.name): 既に最適化済み"
            } else {
                $azArgs += @('-o', 'none')
                Invoke-Change "アプリ $($app.name): $($descParts -join ', ')" $azArgs
            }
        }

        # 5-3. 使用されていない Dedicated プロファイルを削除
        foreach ($p in @($profiles | Where-Object { $_.workloadProfileType -ne 'Consumption' })) {
            # 最新状態で使用中アプリを数え直す
            $apps  = Get-AzJson @('containerapp', 'list', '-g', $rg, '-o', 'json')
            $inUse = @($apps | Where-Object { $_.properties.workloadProfileName -eq $p.name }).Count
            if ($inUse -gt 0) {
                Write-Skip "プロファイル $($p.name) ($($p.workloadProfileType)): $inUse 個のアプリが使用中のため削除しません"
            } else {
                Invoke-Change "プロファイル $($p.name) ($($p.workloadProfileType)) を削除 (Dedicated 課金の停止)" `
                    @('containerapp', 'env', 'workload-profile', 'delete', '-g', $rg, '-n', $envName,
                      '--workload-profile-name', $p.name, '-o', 'none')
            }
        }
    }
}

# ------------------------------------------------------------------
# 6. Azure Cosmos DB
#    ⚠️ 既存アカウントのサーバーレス化 (EnableServerless) は Azure の仕様上
#       不可能です (作成時のみ指定可、逆方向のみ一方向で移行可能)。
#       代替として、プロビジョニング済みスループットを Autoscale へ移行し、
#       最大 RU を最小値まで引き下げます。
# ------------------------------------------------------------------
Write-Head 'Azure Cosmos DB'
Write-Host '   ※ 既存アカウントのサーバーレス化は Azure の仕様上不可能です。'
Write-Host '     代替として Autoscale 化 + 最大 RU の引き下げを行います。'
foreach ($rg in $mrgs) {
    $accounts = az resource list -g $rg --resource-type 'Microsoft.DocumentDB/databaseAccounts' `
        --query "[].name" -o tsv 2>$null
    foreach ($acct in @($accounts | Where-Object { $_ })) {
        Write-Sub "$rg / $acct"

        $caps = az cosmosdb show -g $rg -n $acct --query "capabilities[].name" -o tsv 2>$null
        if ($caps -contains 'EnableServerless') {
            Write-Skip "${acct}: 既にサーバーレスアカウント"
            continue
        }

        $dbs = az cosmosdb sql database list -g $rg -a $acct --query "[].name" -o tsv 2>$null
        foreach ($db in @($dbs | Where-Object { $_ })) {

            # 6-1. データベース単位の共有スループット
            $dbTp = Get-AzJson @('cosmosdb', 'sql', 'database', 'throughput', 'show', '-g', $rg, '-a', $acct, '-n', $db, '-o', 'json')
            if ($dbTp) {
                $auto   = $dbTp.resource.autoscaleSettings.maxThroughput
                $manual = $dbTp.resource.throughput
                if ($auto) {
                    if ($auto -eq $TargetCosmosMaxRu) {
                        Write-Skip "DB ${db}: Autoscale 最大 RU は既に $auto"
                    } else {
                        Invoke-Change "DB ${db}: Autoscale 最大 RU $auto -> $TargetCosmosMaxRu" `
                            @('cosmosdb', 'sql', 'database', 'throughput', 'update', '-g', $rg, '-a', $acct, '-n', $db,
                              '--max-throughput', "$TargetCosmosMaxRu", '-o', 'none')
                    }
                } elseif ($manual) {
                    Invoke-Change "DB ${db}: 手動スループット $manual RU を Autoscale へ移行" `
                        @('cosmosdb', 'sql', 'database', 'throughput', 'migrate', '-g', $rg, '-a', $acct, '-n', $db,
                          '--throughput-type', 'autoscale', '-o', 'none')
                    Invoke-Change "DB ${db}: Autoscale 最大 RU -> $TargetCosmosMaxRu" `
                        @('cosmosdb', 'sql', 'database', 'throughput', 'update', '-g', $rg, '-a', $acct, '-n', $db,
                          '--max-throughput', "$TargetCosmosMaxRu", '-o', 'none')
                }
            }

            # 6-2. コンテナー単位の専用スループット
            $conts = az cosmosdb sql container list -g $rg -a $acct -d $db --query "[].name" -o tsv 2>$null
            foreach ($cont in @($conts | Where-Object { $_ })) {
                $cTp = Get-AzJson @('cosmosdb', 'sql', 'container', 'throughput', 'show', '-g', $rg, '-a', $acct, '-d', $db, '-n', $cont, '-o', 'json')
                if (-not $cTp) { continue }
                $auto   = $cTp.resource.autoscaleSettings.maxThroughput
                $manual = $cTp.resource.throughput
                if ($auto) {
                    if ($auto -eq $TargetCosmosMaxRu) {
                        Write-Skip "コンテナー $db/${cont}: Autoscale 最大 RU は既に $auto"
                    } else {
                        Invoke-Change "コンテナー $db/${cont}: Autoscale 最大 RU $auto -> $TargetCosmosMaxRu" `
                            @('cosmosdb', 'sql', 'container', 'throughput', 'update', '-g', $rg, '-a', $acct, '-d', $db, '-n', $cont,
                              '--max-throughput', "$TargetCosmosMaxRu", '-o', 'none')
                    }
                } elseif ($manual) {
                    Invoke-Change "コンテナー $db/${cont}: 手動スループット $manual RU を Autoscale へ移行" `
                        @('cosmosdb', 'sql', 'container', 'throughput', 'migrate', '-g', $rg, '-a', $acct, '-d', $db, '-n', $cont,
                          '--throughput-type', 'autoscale', '-o', 'none')
                    Invoke-Change "コンテナー $db/${cont}: Autoscale 最大 RU -> $TargetCosmosMaxRu" `
                        @('cosmosdb', 'sql', 'container', 'throughput', 'update', '-g', $rg, '-a', $acct, '-d', $db, '-n', $cont,
                          '--max-throughput', "$TargetCosmosMaxRu", '-o', 'none')
                }
            }
        }
    }
}

# ------------------------------------------------------------------
# 7. Log Analytics ワークスペース
#    - 保持期間を最短 (30 日) に
#    - 日次取り込み上限を設定して想定外の課金を防ぐ
# ------------------------------------------------------------------
Write-Head 'Log Analytics ワークスペース'
foreach ($rg in $mrgs) {
    $laws = az resource list -g $rg --resource-type 'Microsoft.OperationalInsights/workspaces' `
        --query "[].name" -o tsv 2>$null
    foreach ($law in @($laws | Where-Object { $_ })) {
        Write-Sub "$rg / $law"

        $info = Get-AzJson @('monitor', 'log-analytics', 'workspace', 'show', '-g', $rg, '-n', $law, '-o', 'json')
        if (-not $info) {
            Write-Fail "${law}: 情報取得に失敗"
            continue
        }
        $retention = $info.retentionInDays
        $quota     = $info.workspaceCapping.dailyQuotaGb

        if ($retention -eq $TargetLawRetentionDays) {
            Write-Skip "${law}: 保持期間は既に $retention 日"
        } else {
            Invoke-Change "${law}: 保持期間 $retention 日 -> $TargetLawRetentionDays 日" `
                @('monitor', 'log-analytics', 'workspace', 'update', '-g', $rg, '-n', $law,
                  '--retention-time', "$TargetLawRetentionDays", '-o', 'none')
        }

        # dailyQuotaGb は未設定時 -1.0 (無制限)
        if ($quota -eq $TargetLawDailyQuotaGb) {
            Write-Skip "${law}: 日次上限は既に $quota GB"
        } else {
            Invoke-Change "${law}: 日次取り込み上限 $quota -> $TargetLawDailyQuotaGb GB" `
                @('monitor', 'log-analytics', 'workspace', 'update', '-g', $rg, '-n', $law,
                  '--quota', "$TargetLawDailyQuotaGb", '-o', 'none')
        }
    }
}

# ------------------------------------------------------------------
# 8. ストレージアカウント
#    - 冗長性を LRS へ (GRS/ZRS からのダウングレードは可能)
#    - アクセス層を Cool へ (保存容量単価が下がる)
#    ※ Discovery が頻繁に読み書きするアカウントでは Cool 化により
#      トランザクション課金が増える場合があります。効果は要確認。
# ------------------------------------------------------------------
Write-Head 'ストレージアカウント'
foreach ($rg in $mrgs) {
    $stores = Get-AzJson @('storage', 'account', 'list', '-g', $rg, '-o', 'json')
    foreach ($st in @($stores)) {
        $sku  = $st.sku.name
        $tier = $st.accessTier
        Write-Sub "$rg / $($st.name) ($sku / $(if ($tier) { $tier } else { 'N/A' }) / $($st.kind))"

        if ($sku -eq $TargetStorageSku) {
            Write-Skip "$($st.name): 冗長性は既に $sku"
        } else {
            Invoke-Change "$($st.name): 冗長性 $sku -> $TargetStorageSku" `
                @('storage', 'account', 'update', '-g', $rg, '-n', $st.name, '--sku', $TargetStorageSku, '-o', 'none')
        }

        # accessTier は BlobStorage / StorageV2 のみ対応
        if (-not $tier) {
            Write-Skip "$($st.name): アクセス層の設定に非対応 (kind=$($st.kind))"
        } elseif ($tier -eq $TargetStorageTier) {
            Write-Skip "$($st.name): アクセス層は既に $tier"
        } else {
            Invoke-Change "$($st.name): アクセス層 $tier -> $TargetStorageTier" `
                @('storage', 'account', 'update', '-g', $rg, '-n', $st.name, '--access-tier', $TargetStorageTier, '-o', 'none')
        }
    }
}

# ------------------------------------------------------------------
# 9. 対象外リソースの明示
# ------------------------------------------------------------------
Write-Head '対象外 (意図的に変更しないもの)'
Write-Host '   * Azure AI Search        : Basic プランのまま維持します。'
Write-Host '   * Private Endpoint       : 削除すると Discovery が動作しなくなるため触りません。'
Write-Host '   * Private DNS ゾーン     : 同上。'
Write-Host '   * NSP (ネットワーク境界) : 同上。'
Write-Host '   * AI Foundry / OpenAI    : 従量課金のため、アイドル時のコストは発生しません。'
Write-Host ''
Write-Host '   💡 Private Endpoint は 1 本あたり月数ドルの固定費が発生します。'
Write-Host '      本数を減らしたい場合は main.bicep の networkIsolation=false で'
Write-Host '      ワークスペースを作り直してください (本スクリプトでは変更できません)。'

# ------------------------------------------------------------------
# 10. サマリー
# ------------------------------------------------------------------
Write-Head 'サマリー'
if ($Apply) {
    Write-Host "   成功         : $($script:OkCount) 件"
    Write-Host "   スキップ     : $($script:SkipCount) 件 (既に最適化済み / 変更不可)"
    Write-Host "   失敗         : $($script:FailCount) 件"
    if ($script:FailCount -gt 0) {
        Write-Host ''
        Write-Host '   失敗した項目 (Discovery 側の制約により拒否された可能性があります):'
        $script:FailedItems | ForEach-Object { Write-Host "     - $_" }
    }
} else {
    Write-Host '   ドライランのため変更は行っていません。'
    Write-Host '   実際に適用するには -Apply を付けて再実行してください:'
    Write-Host '     ./optimize-mrg.ps1 -Apply'
}
Write-Host ''
Write-Host '   ⚠️ Discovery の再プロビジョニングで設定が元に戻る場合があります。'
Write-Host '      定期的に本スクリプトを再実行してください (冪等です)。'
Write-Host ''

# ベストエフォート方式のため、個別の失敗があっても終了コードは 0 を返す。
exit 0
