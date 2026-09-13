#!/usr/bin/env bash
#
# Microsoft Discovery マネージドリソースグループ (MRG) コスト最適化スクリプト
#
# Workspace / Supercomputer を作ると、Discovery のコントロールプレーンが
# 管理用リソースグループ (mrg-dwsp-* / mrg-dscmp-*) に AKS / Container Apps /
# Cosmos DB / AI Search / Storage / Log Analytics などを自動生成します。
# これらは Microsoft.Discovery の ARM API に設定項目が公開されていないため
# Bicep からは制御できません。本スクリプトはデプロイ後にそれらを
# 「変更できる範囲で」コスト最適化します。
#
# 設計方針:
#   * ベストエフォート。個々のコマンドが失敗しても中断せず最後まで実行します。
#     (Discovery 側の制約で拒否される操作があるのは想定内のため)
#   * 冪等。現在値を確認し、目標値と異なる場合のみ変更します。
#     Discovery の再プロビジョニングで設定が戻るので、何度でも再実行できます。
#   * 既定はドライラン。--apply を付けたときだけ実際に変更します。
#   * Private Endpoint / Private DNS / NSP には一切触れません (削除すると
#     Discovery が動作しなくなるため)。
#
# 使い方:
#   ./optimize-mrg.sh                      # ドライラン (現状と変更予定を表示するのみ)
#   ./optimize-mrg.sh --apply              # 実際に変更を適用
#   ./optimize-mrg.sh --apply --rg myRG    # Discovery リソースが入っている RG を指定して MRG を特定
#
# ⚠️ MRG は Discovery が所有する領域です。手動変更は Microsoft のサポート対象外に
#    なり得ます。また Discovery のバージョンアップや再プロビジョニングで設定が
#    元に戻る場合があります。検証環境での自己責任の実施を推奨します。
#
# 注意: set -e は意図的に使っていません (1 コマンドの失敗で中断させないため)。
set -uo pipefail

export AZURE_CORE_COLLECT_TELEMETRY=0

# ------------------------------------------------------------------
# 0. 設定 (環境変数 / 引数で上書き可能)
# ------------------------------------------------------------------
APPLY=false
DISCOVERY_RG="${RG:-}"

# 目標値
TARGET_AKS_TIER="free"            # AKS クラスター SKU
TARGET_AKS_SYSTEM_NODES=1         # AKS システムノードプールのノード数 (最小 1)
TARGET_ACA_MIN_REPLICAS=0         # Container Apps の最小レプリカ数 (ゼロスケール)
TARGET_ACA_PROFILE="Consumption"  # Container Apps のワークロードプロファイル
TARGET_COSMOS_MAX_RU=1000         # Cosmos DB Autoscale の最大 RU/s (最小値)
TARGET_LAW_RETENTION_DAYS=30      # Log Analytics 保持期間 (最短)
TARGET_LAW_DAILY_QUOTA_GB=1       # Log Analytics 日次取り込み上限
TARGET_STORAGE_SKU="Standard_LRS" # ストレージ冗長性
TARGET_STORAGE_TIER="Cool"        # ストレージアクセス層
TARGET_SQL_OBJECTIVE="GP_S_Gen5_2" # Azure SQL: 汎用サーバーレス 2 vCore
TARGET_SQL_AUTO_PAUSE_MIN=60       # Azure SQL: 自動一時停止までのアイドル分数
TARGET_SEARCH_REPLICAS=1           # AI Search: レプリカ数 (AZ 冗長を捨てて半額化)
TARGET_SEARCH_PARTITIONS=1         # AI Search: パーティション数

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   APPLY=true; shift ;;
    --dry-run) APPLY=false; shift ;;
    --rg)      DISCOVERY_RG="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "不明な引数: $1 (--help でヘルプを表示)" >&2
      exit 2 ;;
  esac
done

# 集計用カウンター
OK_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0
FAILED_ITEMS=()

log()      { echo "$*"; }
log_head() { echo; echo "=============================================================="; echo " $*"; echo "=============================================================="; }
log_sub()  { echo; echo "-- $*"; }
log_skip() { echo "      [SKIP] $*"; SKIP_COUNT=$((SKIP_COUNT + 1)); }
log_ok()   { echo "      [OK]   $*"; OK_COUNT=$((OK_COUNT + 1)); }
log_fail() { echo "      [FAIL] $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_ITEMS+=("$*"); }

# 変更コマンドを実行する共通ラッパー。
# 第1引数は説明文、それ以降が実行するコマンド。
# 失敗しても return 1 を返すだけでスクリプトは継続する。
run_change() {
  local desc="$1"; shift
  if [ "$APPLY" != true ]; then
    echo "      [DRY]  ${desc}"
    echo "             \$ $*"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    return 0
  fi
  local out
  if out=$("$@" 2>&1); then
    log_ok "${desc}"
    return 0
  fi
  log_fail "${desc}"
  echo "             ${out}" | head -3 | sed 's/^/             /'
  return 1
}

log_head "Microsoft Discovery MRG コスト最適化"
if [ "$APPLY" = true ]; then
  log "   モード: APPLY (実際に変更します)"
else
  log "   モード: DRY-RUN (変更内容の表示のみ。--apply で適用)"
fi

# ------------------------------------------------------------------
# 1. ログイン確認
# ------------------------------------------------------------------
SUB_ID=$(az account show --query id -o tsv 2>/dev/null)
if [ -z "${SUB_ID}" ]; then
  echo "az account show に失敗しました。az login を実行してください。" >&2
  exit 1
fi
log "   サブスクリプション: ${SUB_ID}"

# ------------------------------------------------------------------
# 2. 対象 MRG の特定
#    Discovery の MRG 命名規則:
#      Workspace      : mrg-dwsp-<name>-<6桁>
#      Supercomputer  : mrg-dscmp-<name>-<6桁>
#      Bookshelf      : mrg-dbksf-<name>-<6桁>
#    --rg が指定された場合は、その RG 内の Discovery リソース名を使って
#    対象 MRG を絞り込む (同一サブスクに複数環境がある場合の誤爆防止)。
# ------------------------------------------------------------------
MRGS=()
if [ -n "${DISCOVERY_RG}" ]; then
  log "   Discovery RG: ${DISCOVERY_RG} に紐づく MRG を検索します"
  while IFS= read -r disc_name; do
    [ -z "${disc_name}" ] && continue
    while IFS= read -r mrg; do
      [ -z "${mrg}" ] && continue
      MRGS+=("${mrg}")
    done < <(az group list --query "[?contains(name, '${disc_name}')].name" -o tsv 2>/dev/null)
  done < <(az resource list -g "${DISCOVERY_RG}" \
             --query "[?starts_with(type,'Microsoft.Discovery/')].name" -o tsv 2>/dev/null)
  # 重複排除
  if [ ${#MRGS[@]} -gt 0 ]; then
    mapfile -t MRGS < <(printf '%s\n' "${MRGS[@]}" | sort -u)
  fi
fi

if [ ${#MRGS[@]} -eq 0 ]; then
  mapfile -t MRGS < <(az group list \
    --query "[?starts_with(name,'mrg-dwsp-') || starts_with(name,'mrg-dscmp-') || starts_with(name,'mrg-dbksf-')].name" \
    -o tsv 2>/dev/null)
fi

if [ ${#MRGS[@]} -eq 0 ]; then
  log "   対象の MRG が見つかりませんでした。Discovery のデプロイが完了しているか確認してください。"
  exit 0
fi

log "   対象 MRG: ${#MRGS[@]} 件"
printf '     - %s\n' "${MRGS[@]}"

# ------------------------------------------------------------------
# 3. 事前チェック: 拒否割り当て (deny assignment) とリソースロック
#    これらが存在すると Owner であっても変更が拒否される。
#    見つかっても中断はせず、警告のみ出して処理を続行する。
# ------------------------------------------------------------------
log_head "事前チェック (拒否割り当て / ロック)"
for rg in "${MRGS[@]}"; do
  log_sub "${rg}"
  deny=$(az rest --method get \
    --url "https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${rg}/providers/Microsoft.Authorization/denyAssignments?api-version=2022-04-01" \
    --query "value[].properties.denyAssignmentName" -o tsv 2>/dev/null)
  if [ -n "${deny}" ]; then
    log "      ⚠️ 拒否割り当てあり: ${deny}"
    log "         Owner 権限でも一部の変更が拒否される可能性があります。"
  else
    log "      拒否割り当て: なし"
  fi
  locks=$(az lock list -g "${rg}" --query "[].name" -o tsv 2>/dev/null)
  if [ -n "${locks}" ]; then
    log "      ⚠️ リソースロックあり: ${locks}"
  else
    log "      リソースロック: なし"
  fi
done

# ------------------------------------------------------------------
# 4. AKS (Supercomputer の内部クラスター)
#    - クラスター SKU tier を Free に (Standard は SLA 付きで有償)
#    - システムノードプールを 1 台に (システムプールの下限は 1。0 にはできない)
# ------------------------------------------------------------------
log_head "AKS クラスター"
for rg in "${MRGS[@]}"; do
  while IFS= read -r aks; do
    [ -z "${aks}" ] && continue
    log_sub "${rg} / ${aks}"

    tier=$(az aks show -g "${rg}" -n "${aks}" --query "sku.tier" -o tsv 2>/dev/null)
    if [ -z "${tier}" ]; then
      log_fail "AKS ${aks}: 情報取得に失敗"
    elif [ "$(echo "${tier}" | tr '[:upper:]' '[:lower:]')" = "${TARGET_AKS_TIER}" ]; then
      log_skip "AKS ${aks}: SKU tier は既に ${tier}"
    else
      run_change "AKS ${aks}: SKU tier ${tier} -> ${TARGET_AKS_TIER}" \
        az aks update -g "${rg}" -n "${aks}" --tier "${TARGET_AKS_TIER}" -o none
    fi

    # システムノードプール (mode=System) を 1 台へ。
    # オートスケーラーが有効な場合は min/max の更新、無効な場合は scale を使う。
    while IFS=$'\t' read -r pool mode count autoscale mincount maxcount; do
      [ -z "${pool}" ] && continue
      [ "${mode}" != "System" ] && continue

      if [ "${autoscale}" = "true" ]; then
        if [ "${mincount}" = "${TARGET_AKS_SYSTEM_NODES}" ] && [ "${maxcount}" = "${TARGET_AKS_SYSTEM_NODES}" ]; then
          log_skip "AKS ${aks}/${pool}: オートスケール範囲は既に ${TARGET_AKS_SYSTEM_NODES}-${TARGET_AKS_SYSTEM_NODES}"
        else
          run_change "AKS ${aks}/${pool}: オートスケール範囲 ${mincount}-${maxcount} -> ${TARGET_AKS_SYSTEM_NODES}-${TARGET_AKS_SYSTEM_NODES}" \
            az aks nodepool update -g "${rg}" --cluster-name "${aks}" -n "${pool}" \
              --update-cluster-autoscaler --min-count "${TARGET_AKS_SYSTEM_NODES}" --max-count "${TARGET_AKS_SYSTEM_NODES}" -o none
        fi
      else
        if [ "${count}" = "${TARGET_AKS_SYSTEM_NODES}" ]; then
          log_skip "AKS ${aks}/${pool}: ノード数は既に ${count}"
        else
          run_change "AKS ${aks}/${pool}: ノード数 ${count} -> ${TARGET_AKS_SYSTEM_NODES}" \
            az aks nodepool scale -g "${rg}" --cluster-name "${aks}" -n "${pool}" \
              --node-count "${TARGET_AKS_SYSTEM_NODES}" -o none
        fi
      fi
    done < <(az aks show -g "${rg}" -n "${aks}" \
               --query "agentPoolProfiles[].[name,mode,count,enableAutoScaling,minCount,maxCount]" \
               -o tsv 2>/dev/null)
  done < <(az resource list -g "${rg}" \
             --resource-type "Microsoft.ContainerService/managedClusters" --query "[].name" -o tsv 2>/dev/null)
done

# ------------------------------------------------------------------
# 5. Azure Container Apps
#    - 各アプリを従量課金 (Consumption) プロファイルへ移し、最小レプリカを 0 に
#      (ゼロスケール化)
#    - 全アプリの移行後、Dedicated (D シリーズ等) プロファイルを削除
#    ※ 環境の種類 (ワークロードプロファイル型 / Consumption 専用型) は作成時に
#      固定で後から変更できないため、Consumption プロファイルのみを残す形にする。
# ------------------------------------------------------------------
log_head "Azure Container Apps"
for rg in "${MRGS[@]}"; do
  while IFS= read -r env; do
    [ -z "${env}" ] && continue
    log_sub "${rg} / ${env}"

    # 5-1. Consumption プロファイルが無ければ追加
    profiles=$(az containerapp env workload-profile list -g "${rg}" -n "${env}" \
                 --query "[].[name,workloadProfileType]" -o tsv 2>/dev/null)
    if [ -z "${profiles}" ]; then
      log_skip "${env}: ワークロードプロファイル情報を取得できませんでした (Consumption 専用環境の可能性)"
    else
      if ! echo "${profiles}" | awk -F'\t' '{print $2}' | grep -qi '^Consumption$'; then
        run_change "${env}: Consumption プロファイルを追加" \
          az containerapp env workload-profile add -g "${rg}" -n "${env}" \
            --workload-profile-name "${TARGET_ACA_PROFILE}" --workload-profile-type Consumption -o none
      else
        log_skip "${env}: Consumption プロファイルは既に存在"
      fi
    fi

    # 5-2. 各アプリを Consumption + 最小レプリカ 0 へ
    while IFS=$'\t' read -r app profile minrep; do
      [ -z "${app}" ] && continue
      args=()
      desc_parts=()
      if [ -n "${profiles}" ] && [ "${profile}" != "${TARGET_ACA_PROFILE}" ]; then
        args+=(--workload-profile-name "${TARGET_ACA_PROFILE}")
        desc_parts+=("プロファイル ${profile:-未設定} -> ${TARGET_ACA_PROFILE}")
      fi
      if [ "${minrep}" != "${TARGET_ACA_MIN_REPLICAS}" ]; then
        args+=(--min-replicas "${TARGET_ACA_MIN_REPLICAS}")
        desc_parts+=("最小レプリカ ${minrep} -> ${TARGET_ACA_MIN_REPLICAS}")
      fi
      if [ ${#args[@]} -eq 0 ]; then
        log_skip "アプリ ${app}: 既に最適化済み"
      else
        old_ifs="$IFS"; IFS=', '; desc="${desc_parts[*]}"; IFS="$old_ifs"
        run_change "アプリ ${app}: ${desc}" \
          az containerapp update -g "${rg}" -n "${app}" "${args[@]}" -o none
      fi
    done < <(az containerapp list -g "${rg}" \
               --query "[?contains(properties.environmentId, '/${env}')].[name, properties.workloadProfileName, properties.template.scale.minReplicas]" \
               -o tsv 2>/dev/null)

    # 5-3. 使用されていない Dedicated プロファイルを削除
    #      (使用中のアプリが 1 つでもあれば削除は失敗するので、事前に確認する)
    while IFS=$'\t' read -r pname ptype; do
      [ -z "${pname}" ] && continue
      # Consumption 型は従量課金なので残す
      if echo "${ptype}" | grep -qi '^Consumption$'; then
        continue
      fi
      inuse=$(az containerapp list -g "${rg}" \
                --query "length([?properties.workloadProfileName=='${pname}'])" -o tsv 2>/dev/null)
      if [ "${inuse:-0}" != "0" ]; then
        log_skip "プロファイル ${pname} (${ptype}): ${inuse} 個のアプリが使用中のため削除しません"
      else
        run_change "プロファイル ${pname} (${ptype}) を削除 (Dedicated 課金の停止)" \
          az containerapp env workload-profile delete -g "${rg}" -n "${env}" \
            --workload-profile-name "${pname}" -o none
      fi
    done < <(echo "${profiles}")
  done < <(az resource list -g "${rg}" \
             --resource-type "Microsoft.App/managedEnvironments" --query "[].name" -o tsv 2>/dev/null)
done

# ------------------------------------------------------------------
# 6. Azure Cosmos DB
#    ⚠️ 既存アカウントのサーバーレス化 (EnableServerless) は Azure の仕様上
#       不可能です (作成時のみ指定可、逆方向のみ一方向で移行可能)。
#       代替として、プロビジョニング済みスループットを Autoscale へ移行し、
#       最大 RU を最小値まで引き下げます。
# ------------------------------------------------------------------
log_head "Azure Cosmos DB"
log "   ※ 既存アカウントのサーバーレス化は Azure の仕様上不可能です。"
log "     代替として Autoscale 化 + 最大 RU の引き下げを行います。"
for rg in "${MRGS[@]}"; do
  while IFS= read -r acct; do
    [ -z "${acct}" ] && continue
    log_sub "${rg} / ${acct}"

    caps=$(az cosmosdb show -g "${rg}" -n "${acct}" --query "capabilities[].name" -o tsv 2>/dev/null)
    if echo "${caps}" | grep -q 'EnableServerless'; then
      log_skip "${acct}: 既にサーバーレスアカウント"
      continue
    fi

    while IFS= read -r db; do
      [ -z "${db}" ] && continue

      # 6-1. データベース単位の共有スループット
      db_tp=$(az cosmosdb sql database throughput show -g "${rg}" -a "${acct}" -n "${db}" \
                --query "resource.[throughput, autoscaleSettings.maxThroughput]" -o tsv 2>/dev/null)
      if [ -n "${db_tp}" ]; then
        manual=$(echo "${db_tp}" | awk -F'\t' '{print $1}')
        auto=$(echo "${db_tp}" | awk -F'\t' '{print $2}')
        if [ -n "${auto}" ] && [ "${auto}" != "None" ]; then
          if [ "${auto}" = "${TARGET_COSMOS_MAX_RU}" ]; then
            log_skip "DB ${db}: Autoscale 最大 RU は既に ${auto}"
          else
            run_change "DB ${db}: Autoscale 最大 RU ${auto} -> ${TARGET_COSMOS_MAX_RU}" \
              az cosmosdb sql database throughput update -g "${rg}" -a "${acct}" -n "${db}" \
                --max-throughput "${TARGET_COSMOS_MAX_RU}" -o none
          fi
        elif [ -n "${manual}" ] && [ "${manual}" != "None" ]; then
          run_change "DB ${db}: 手動スループット ${manual} RU を Autoscale へ移行" \
            az cosmosdb sql database throughput migrate -g "${rg}" -a "${acct}" -n "${db}" \
              --throughput-type autoscale -o none
          run_change "DB ${db}: Autoscale 最大 RU -> ${TARGET_COSMOS_MAX_RU}" \
            az cosmosdb sql database throughput update -g "${rg}" -a "${acct}" -n "${db}" \
              --max-throughput "${TARGET_COSMOS_MAX_RU}" -o none
        fi
      fi

      # 6-2. コンテナー単位の専用スループット
      while IFS= read -r cont; do
        [ -z "${cont}" ] && continue
        c_tp=$(az cosmosdb sql container throughput show -g "${rg}" -a "${acct}" -d "${db}" -n "${cont}" \
                 --query "resource.[throughput, autoscaleSettings.maxThroughput]" -o tsv 2>/dev/null)
        [ -z "${c_tp}" ] && continue
        manual=$(echo "${c_tp}" | awk -F'\t' '{print $1}')
        auto=$(echo "${c_tp}" | awk -F'\t' '{print $2}')
        if [ -n "${auto}" ] && [ "${auto}" != "None" ]; then
          if [ "${auto}" = "${TARGET_COSMOS_MAX_RU}" ]; then
            log_skip "コンテナー ${db}/${cont}: Autoscale 最大 RU は既に ${auto}"
          else
            run_change "コンテナー ${db}/${cont}: Autoscale 最大 RU ${auto} -> ${TARGET_COSMOS_MAX_RU}" \
              az cosmosdb sql container throughput update -g "${rg}" -a "${acct}" -d "${db}" -n "${cont}" \
                --max-throughput "${TARGET_COSMOS_MAX_RU}" -o none
          fi
        elif [ -n "${manual}" ] && [ "${manual}" != "None" ]; then
          run_change "コンテナー ${db}/${cont}: 手動スループット ${manual} RU を Autoscale へ移行" \
            az cosmosdb sql container throughput migrate -g "${rg}" -a "${acct}" -d "${db}" -n "${cont}" \
              --throughput-type autoscale -o none
          run_change "コンテナー ${db}/${cont}: Autoscale 最大 RU -> ${TARGET_COSMOS_MAX_RU}" \
            az cosmosdb sql container throughput update -g "${rg}" -a "${acct}" -d "${db}" -n "${cont}" \
              --max-throughput "${TARGET_COSMOS_MAX_RU}" -o none
        fi
      done < <(az cosmosdb sql container list -g "${rg}" -a "${acct}" -d "${db}" --query "[].name" -o tsv 2>/dev/null)
    done < <(az cosmosdb sql database list -g "${rg}" -a "${acct}" --query "[].name" -o tsv 2>/dev/null)
  done < <(az resource list -g "${rg}" \
             --resource-type "Microsoft.DocumentDB/databaseAccounts" --query "[].name" -o tsv 2>/dev/null)
done

# ------------------------------------------------------------------
# 7. Log Analytics ワークスペース
#    - 保持期間を最短 (30 日) に
#    - 日次取り込み上限を設定して想定外の課金を防ぐ
# ------------------------------------------------------------------
log_head "Log Analytics ワークスペース"
for rg in "${MRGS[@]}"; do
  while IFS= read -r law; do
    [ -z "${law}" ] && continue
    log_sub "${rg} / ${law}"

    info=$(az monitor log-analytics workspace show -g "${rg}" -n "${law}" \
             --query "[retentionInDays, workspaceCapping.dailyQuotaGb]" -o tsv 2>/dev/null)
    retention=$(echo "${info}" | awk -F'\t' '{print $1}')
    quota=$(echo "${info}" | awk -F'\t' '{print $2}')

    if [ "${retention}" = "${TARGET_LAW_RETENTION_DAYS}" ]; then
      log_skip "${law}: 保持期間は既に ${retention} 日"
    else
      run_change "${law}: 保持期間 ${retention} 日 -> ${TARGET_LAW_RETENTION_DAYS} 日" \
        az monitor log-analytics workspace update -g "${rg}" -n "${law}" \
          --retention-time "${TARGET_LAW_RETENTION_DAYS}" -o none
    fi

    # dailyQuotaGb は未設定時 -1.0 (無制限)
    if [ "${quota}" = "${TARGET_LAW_DAILY_QUOTA_GB}" ] || [ "${quota}" = "${TARGET_LAW_DAILY_QUOTA_GB}.0" ]; then
      log_skip "${law}: 日次上限は既に ${quota} GB"
    else
      run_change "${law}: 日次取り込み上限 ${quota} -> ${TARGET_LAW_DAILY_QUOTA_GB} GB" \
        az monitor log-analytics workspace update -g "${rg}" -n "${law}" \
          --quota "${TARGET_LAW_DAILY_QUOTA_GB}" -o none
    fi
  done < <(az resource list -g "${rg}" \
             --resource-type "Microsoft.OperationalInsights/workspaces" --query "[].name" -o tsv 2>/dev/null)
done

# ------------------------------------------------------------------
# 8. ストレージアカウント
#    - 冗長性を LRS へ (GRS/ZRS からのダウングレードは可能)
#    - アクセス層を Cool へ (保存容量単価が下がる)
#    ※ Discovery が頻繁に読み書きするアカウントでは Cool 化により
#      トランザクション課金が増える場合があります。効果は要確認。
# ------------------------------------------------------------------
log_head "ストレージアカウント"
for rg in "${MRGS[@]}"; do
  while IFS=$'\t' read -r st sku tier kind; do
    [ -z "${st}" ] && continue
    log_sub "${rg} / ${st} (${sku} / ${tier:-N/A} / ${kind})"

    if [ "${sku}" = "${TARGET_STORAGE_SKU}" ]; then
      log_skip "${st}: 冗長性は既に ${sku}"
    else
      run_change "${st}: 冗長性 ${sku} -> ${TARGET_STORAGE_SKU}" \
        az storage account update -g "${rg}" -n "${st}" --sku "${TARGET_STORAGE_SKU}" -o none
    fi

    # accessTier は BlobStorage / StorageV2 のみ。それ以外は None が返る。
    if [ -z "${tier}" ] || [ "${tier}" = "None" ]; then
      log_skip "${st}: アクセス層の設定に非対応 (kind=${kind})"
    elif [ "${tier}" = "${TARGET_STORAGE_TIER}" ]; then
      log_skip "${st}: アクセス層は既に ${tier}"
    else
      run_change "${st}: アクセス層 ${tier} -> ${TARGET_STORAGE_TIER}" \
        az storage account update -g "${rg}" -n "${st}" --access-tier "${TARGET_STORAGE_TIER}" -o none
    fi
  done < <(az storage account list -g "${rg}" \
             --query "[].[name, sku.name, accessTier, kind]" -o tsv 2>/dev/null)
done

# ------------------------------------------------------------------
# 9. Azure SQL Database (Bookshelf の Knowledge Base グラフ保存先)
#    Bookshelf は既定で Hyperscale / ゾーン冗長の DB を作るため、アイドル時でも
#    固定費が大きい。汎用サーバーレス + 自動一時停止へ寄せてアイドル課金を止める。
#    ※ Hyperscale からのエディション変更は拒否されることがあるためベストエフォート。
# ------------------------------------------------------------------
log_head "Azure SQL Database (Bookshelf)"
for rg in "${MRGS[@]}"; do
  while IFS= read -r sqlsrv; do
    [ -z "${sqlsrv}" ] && continue
    while IFS=$'\t' read -r db objective zoned; do
      [ -z "${db}" ] && continue
      [ "${db}" = "master" ] && continue
      log_sub "${rg} / ${sqlsrv} / ${db} (${objective})"

      if [ "${objective}" = "${TARGET_SQL_OBJECTIVE}" ]; then
        log_skip "DB ${db}: 既に ${TARGET_SQL_OBJECTIVE}"
      else
        run_change "DB ${db}: ${objective} -> ${TARGET_SQL_OBJECTIVE} (サーバーレス + 自動一時停止 ${TARGET_SQL_AUTO_PAUSE_MIN} 分)" \
          az sql db update -g "${rg}" -s "${sqlsrv}" -n "${db}" \
            --edition GeneralPurpose --family Gen5 --capacity 2 \
            --compute-model Serverless --auto-pause-delay "${TARGET_SQL_AUTO_PAUSE_MIN}" -o none
      fi

      if [ "${zoned}" = "true" ]; then
        run_change "DB ${db}: ゾーン冗長を無効化" \
          az sql db update -g "${rg}" -s "${sqlsrv}" -n "${db}" --zone-redundant false -o none
      else
        log_skip "DB ${db}: ゾーン冗長は無効"
      fi
    done < <(az sql db list -g "${rg}" -s "${sqlsrv}" \
               --query "[].[name, currentServiceObjectiveName, zoneRedundant]" -o tsv 2>/dev/null)
  done < <(az sql server list -g "${rg}" --query "[].name" -o tsv 2>/dev/null)
done

# ------------------------------------------------------------------
# 10. Azure AI Search (Bookshelf の Knowledge Base 検索)
#     Bookshelf は既定で Standard S1 x 2 レプリカ (可用性ゾーン対応) を作る。
#     検証用途ではレプリカ 1 で十分なため、半額化する。
#     ※ SKU (S1 など) は作成時のみ指定可能で、後から変更できません。
# ------------------------------------------------------------------
log_head "Azure AI Search (Bookshelf)"
log "   ※ SKU は作成時固定のため変更できません。レプリカ / パーティション数のみ調整します。"
for rg in "${MRGS[@]}"; do
  while IFS=$'\t' read -r svc sku replicas partitions; do
    [ -z "${svc}" ] && continue
    log_sub "${rg} / ${svc} (${sku} / replicas=${replicas} / partitions=${partitions})"

    args=()
    desc_parts=()
    if [ "${replicas}" != "${TARGET_SEARCH_REPLICAS}" ]; then
      args+=(--replica-count "${TARGET_SEARCH_REPLICAS}")
      desc_parts+=("レプリカ ${replicas} -> ${TARGET_SEARCH_REPLICAS}")
    fi
    if [ "${partitions}" != "${TARGET_SEARCH_PARTITIONS}" ]; then
      args+=(--partition-count "${TARGET_SEARCH_PARTITIONS}")
      desc_parts+=("パーティション ${partitions} -> ${TARGET_SEARCH_PARTITIONS}")
    fi

    if [ ${#args[@]} -eq 0 ]; then
      log_skip "${svc}: 既に最小構成"
    else
      old_ifs="$IFS"; IFS=', '; desc="${desc_parts[*]}"; IFS="$old_ifs"
      run_change "${svc}: ${desc}" \
        az search service update -g "${rg}" -n "${svc}" "${args[@]}" -o none
    fi
  done < <(az search service list -g "${rg}" \
             --query "[].[name, sku.name, replicaCount, partitionCount]" -o tsv 2>/dev/null)
done

# ------------------------------------------------------------------
# 11. 対象外リソースの明示
# ------------------------------------------------------------------
log_head "対象外 (意図的に変更しないもの)"
log "   * AI Search の SKU      : 作成時固定のため変更できません (レプリカ数のみ調整)。"
log "   * Private Endpoint       : 削除すると Discovery が動作しなくなるため触りません。"
log "   * Private DNS ゾーン     : 同上。"
log "   * NSP (ネットワーク境界) : 同上。"
log "   * AI Foundry / OpenAI    : 従量課金のため、アイドル時のコストは発生しません。"
log ""
log "   💡 Private Endpoint は 1 本あたり月数ドルの固定費が発生します。"
log "      本数を減らしたい場合は main.bicep の networkIsolation=false で"
log "      ワークスペースを作り直してください (本スクリプトでは変更できません)。"
log ""
log "   💡 Bookshelf を使わない期間は deploy 時に SKIP_BOOKSHELF=1 を指定するか、"
log "      Bookshelf リソースごと削除するのが最も確実なコスト削減です。"

# ------------------------------------------------------------------
# 12. サマリー
# ------------------------------------------------------------------
log_head "サマリー"
if [ "$APPLY" = true ]; then
  log "   成功         : ${OK_COUNT} 件"
  log "   スキップ     : ${SKIP_COUNT} 件 (既に最適化済み / 変更不可)"
  log "   失敗         : ${FAIL_COUNT} 件"
  if [ ${FAIL_COUNT} -gt 0 ]; then
    log ""
    log "   失敗した項目 (Discovery 側の制約により拒否された可能性があります):"
    printf '     - %s\n' "${FAILED_ITEMS[@]}"
  fi
else
  log "   ドライランのため変更は行っていません。"
  log "   実際に適用するには --apply を付けて再実行してください:"
  log "     ./optimize-mrg.sh --apply"
fi
log ""
log "   ⚠️ Discovery の再プロビジョニングで設定が元に戻る場合があります。"
log "      定期的に本スクリプトを再実行してください (冪等です)。"
log ""

# ベストエフォート方式のため、個別の失敗があっても終了コードは 0 を返す。
exit 0
