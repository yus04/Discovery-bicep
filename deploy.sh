#!/usr/bin/env bash
#
# Microsoft Discovery インフラ デプロイスクリプト (Bicep クイックスタート)
# 参考: https://learn.microsoft.com/ja-jp/azure/microsoft-discovery/quickstart-infrastructure-bicep
#
# 使い方:
#   ./deploy.sh                  # 既定値 (swedencentral / discoveryRG) でデプロイ
#   LOCATION=eastus ./deploy.sh  # リージョンを変更 (対応: eastus/uksouth/swedencentral)
#   RG=myDiscoveryRG ./deploy.sh # リソースグループ名を変更
#   DEPLOYMENT_MODE=Production ./deploy.sh # 本番モード (既定: CostOptimized)
#   SKIP_MRG_OPTIMIZE=1 ./deploy.sh        # デプロイ後の MRG 最適化をスキップ
#   SKIP_BOOKSHELF=1 ./deploy.sh           # Bookshelf / Knowledge ストレージを作らない
#   SKIP_TOOLS=1 ./deploy.sh               # Discovery ツールを作らない
#   BOOKSHELF_INDEX_SIZE=medium ./deploy.sh # Bookshelf の indexSize を明示指定
#
set -euo pipefail

# ------------------------------------------------------------------
# 0. 設定 (環境変数で上書き可能)
# ------------------------------------------------------------------
LOCATION="${LOCATION:-swedencentral}"
RG="${RG:-discoveryRG}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-discovery-$(date +%Y%m%d-%H%M%S)}"
TEMPLATE_FILE="${TEMPLATE_FILE:-main.bicep}"
# コストプリセット: CostOptimized (既定) = ランニングコスト最小構成 / Production = 従来設定
DEPLOYMENT_MODE="${DEPLOYMENT_MODE:-CostOptimized}"
# 1 を指定すると、コスト最適化モードでもデプロイ後の MRG 最適化を実行しない
SKIP_MRG_OPTIMIZE="${SKIP_MRG_OPTIMIZE:-0}"
# 1 を指定すると Bookshelf / Discovery ツールをデプロイしない
SKIP_BOOKSHELF="${SKIP_BOOKSHELF:-0}"
SKIP_TOOLS="${SKIP_TOOLS:-0}"
# 空文字のときは deploymentMode のプリセット (CostOptimized: small / Production: medium)
BOOKSHELF_INDEX_SIZE="${BOOKSHELF_INDEX_SIZE:-}"

[ "${SKIP_BOOKSHELF}" = "1" ] && DEPLOY_BOOKSHELF=false || DEPLOY_BOOKSHELF=true
[ "${SKIP_TOOLS}" = "1" ]     && DEPLOY_TOOLS=false     || DEPLOY_TOOLS=true

# az CLI のテレメトリ収集を無効化 (環境によってはクラッシュ回避のため必須)
export AZURE_CORE_COLLECT_TELEMETRY=0

echo "=================================================="
echo " Microsoft Discovery デプロイ"
echo "   リージョン        : ${LOCATION}"
echo "   リソースグループ  : ${RG}"
echo "   デプロイ名        : ${DEPLOYMENT_NAME}"
echo "   テンプレート      : ${TEMPLATE_FILE}"
echo "   コストモード      : ${DEPLOYMENT_MODE}"
echo "   Bookshelf         : ${DEPLOY_BOOKSHELF} (indexSize: ${BOOKSHELF_INDEX_SIZE:-モード既定})"
echo "   Discovery ツール  : ${DEPLOY_TOOLS}"
echo "=================================================="

# ------------------------------------------------------------------
# 1. ログイン確認
# ------------------------------------------------------------------
echo "[1/6] ログイン状態を確認..."
SUB_ID=$(az account show --query id -o tsv)
SUB_NAME=$(az account show --query name -o tsv)
echo "      サブスクリプション: ${SUB_NAME} (${SUB_ID})"

# ------------------------------------------------------------------
# 2. リソースプロバイダー登録
#    ※ Discovery はプレビューのため、登録が完了していないと
#      "Cannot access Supercomputer" 等のエラーになり得る
# ------------------------------------------------------------------
echo "[2/6] Microsoft.Discovery プロバイダーを登録..."
az provider register --namespace Microsoft.Discovery --only-show-errors >/dev/null

# 登録完了まで待機 (最大5分)
for i in $(seq 1 30); do
  STATE=$(az provider show --namespace Microsoft.Discovery --query registrationState -o tsv)
  if [ "${STATE}" = "Registered" ]; then
    echo "      プロバイダー登録済み: ${STATE}"
    break
  fi
  echo "      登録待機中 (${STATE})... ${i}/30"
  sleep 10
done

# ------------------------------------------------------------------
# 2b. Discovery 第1パーティ SP (Discovery control-plane service App) を確認
#     App ID は固定。main.bicep の discoveryControlPlanePrincipalId は必須なので
#     ここで Object ID を解決して渡す。
# ------------------------------------------------------------------
echo "[2b/6] Discovery control-plane サービスプリンシパルを確認..."
DISCOVERY_APP_ID="92c174ac-8e41-4815-a1b7-d81b19ab03ce"
DISCOVERY_PRINCIPAL_ID=$(az ad sp show --id "${DISCOVERY_APP_ID}" --query id -o tsv 2>/dev/null || true)
if [ -z "${DISCOVERY_PRINCIPAL_ID}" ]; then
  echo "      テナントに SP が未作成。作成します..."
  az ad sp create --id "${DISCOVERY_APP_ID}" --only-show-errors -o none
  DISCOVERY_PRINCIPAL_ID=$(az ad sp show --id "${DISCOVERY_APP_ID}" --query id -o tsv)
fi
echo "      Discovery SP Object ID: ${DISCOVERY_PRINCIPAL_ID}"

# サインインユーザーを Discovery Studio 管理者にする (取得できなければ空配列)
SIGNED_IN_USER_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
if [ -n "${SIGNED_IN_USER_ID}" ]; then
  WORKSPACE_ADMINS_JSON="[\"${SIGNED_IN_USER_ID}\"]"
  echo "      Discovery Studio 管理者 (自動): ${SIGNED_IN_USER_ID}"
else
  WORKSPACE_ADMINS_JSON="[]"
  echo "      ⚠️ サインインユーザーの Object ID を取得できませんでした。Studio 権限は付与されません。"
fi

# ------------------------------------------------------------------
# 3. リソースグループ作成 (べき等)
# ------------------------------------------------------------------
echo "[3/6] リソースグループを作成..."
az group create --name "${RG}" --location "${LOCATION}" --only-show-errors -o none
echo "      OK: ${RG} (${LOCATION})"

# ------------------------------------------------------------------
# 4. Bicep テンプレートの検証
# ------------------------------------------------------------------
TEMPLATE_PARAMS=(
  location="${LOCATION}"
  deploymentMode="${DEPLOYMENT_MODE}"
  deployBookshelf="${DEPLOY_BOOKSHELF}"
  deployTools="${DEPLOY_TOOLS}"
  discoveryControlPlanePrincipalId="${DISCOVERY_PRINCIPAL_ID}"
  workspaceAdminPrincipalIds="${WORKSPACE_ADMINS_JSON}"
)
if [ -n "${BOOKSHELF_INDEX_SIZE}" ]; then
  TEMPLATE_PARAMS+=(bookshelfIndexSize="${BOOKSHELF_INDEX_SIZE}")
fi

echo "[4/6] テンプレートを検証 (what-if 省略, validate のみ)..."
az deployment group validate \
  --resource-group "${RG}" \
  --template-file "${TEMPLATE_FILE}" \
  --parameters "${TEMPLATE_PARAMS[@]}" \
  --only-show-errors -o none
echo "      検証 OK"

# ------------------------------------------------------------------
# 5. デプロイ実行
# ------------------------------------------------------------------
echo "[5/6] デプロイ実行 (スパコン作成に20分以上かかる場合があります)..."
az deployment group create \
  --resource-group "${RG}" \
  --name "${DEPLOYMENT_NAME}" \
  --template-file "${TEMPLATE_FILE}" \
  --parameters "${TEMPLATE_PARAMS[@]}" \
  --query "{state:properties.provisioningState, ws:properties.outputs.workspaceId.value, mode:properties.outputs.deploymentModeApplied.value, bookshelf:properties.outputs.bookshelfEndpoint.value, tools:properties.outputs.toolNames.value}" \
  -o json

# ------------------------------------------------------------------
# 6. マネージドリソースグループ (MRG) のコスト最適化
#    Discovery が自動生成する AKS / Container Apps / Cosmos DB などは
#    Bicep から制御できないため、デプロイ後にスクリプトで最適化する。
#    ベストエフォート方式のため、一部が失敗しても全体は継続する。
# ------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${DEPLOYMENT_MODE}" = "CostOptimized" ] && [ "${SKIP_MRG_OPTIMIZE}" != "1" ]; then
  echo "[6/6] マネージドリソースグループのコスト最適化..."
  if [ -x "${SCRIPT_DIR}/optimize-mrg.sh" ]; then
    # set -e 下でも中断しないように || true を付ける
    "${SCRIPT_DIR}/optimize-mrg.sh" --apply --rg "${RG}" || true
  else
    echo "      optimize-mrg.sh が見つからないためスキップします。"
  fi
else
  echo "[6/6] マネージドリソースグループの最適化はスキップします (mode=${DEPLOYMENT_MODE})。"
fi

echo "=================================================="
echo " 完了。各リソースの状態は以下で確認できます:"
echo "   az resource list -g ${RG} --query \"[?contains(type,'Microsoft.Discovery')].{name:name,type:type}\" -o table"
if [ "${DEPLOY_BOOKSHELF}" = "true" ]; then
  echo ""
  echo " Knowledge Base の作成手順 (Bookshelf は作成済み):"
  echo "   1. knowledgedocuments コンテナーに PDF/DOCX/PPTX/XLSX/TXT/HTML をアップロード"
  echo "   2. Discovery Studio > Resources > Knowledge で Bookshelf を選択し + Create new"
  echo "   3. Storage Container / Storage Asset / User Assigned Identity は本テンプレートが作成済みのものを選択"
  echo "   4. Index を実行 (大きなデータにはメモリ最適化 VM の Node Pool を別途用意)"
fi
echo "=================================================="
