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

# az CLI のテレメトリ収集を無効化 (環境によってはクラッシュ回避のため必須)
export AZURE_CORE_COLLECT_TELEMETRY=0

echo "=================================================="
echo " Microsoft Discovery デプロイ"
echo "   リージョン        : ${LOCATION}"
echo "   リソースグループ  : ${RG}"
echo "   デプロイ名        : ${DEPLOYMENT_NAME}"
echo "   テンプレート      : ${TEMPLATE_FILE}"
echo "   コストモード      : ${DEPLOYMENT_MODE}"
echo "=================================================="

# ------------------------------------------------------------------
# 1. ログイン確認
# ------------------------------------------------------------------
echo "[1/6] ログイン状態を確認..."
SUB_ID=$(az account show --query id -o tsv)
SUB_NAME=$(az account show --query name -o tsv)
echo "      サブスクリプション: ${SUB_NAME} (${SUB_ID})"

# ------------------------------------------------------------------
# 2. リソースプロバイダー & フィーチャー登録
#    ※ Discovery はプレビューのため、登録が完了していないと
#      "Cannot access Supercomputer" 等のエラーになり得る
# ------------------------------------------------------------------
echo "[2/6] Microsoft.Discovery プロバイダーを登録..."
az feature register --namespace Microsoft.Discovery --name DiscoveryEnabled --only-show-errors >/dev/null || true
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
# 3. リソースグループ作成 (べき等)
# ------------------------------------------------------------------
echo "[3/6] リソースグループを作成..."
az group create --name "${RG}" --location "${LOCATION}" --only-show-errors -o none
echo "      OK: ${RG} (${LOCATION})"

# ------------------------------------------------------------------
# 4. Bicep テンプレートの検証
# ------------------------------------------------------------------
echo "[4/6] テンプレートを検証 (what-if 省略, validate のみ)..."
az deployment group validate \
  --resource-group "${RG}" \
  --template-file "${TEMPLATE_FILE}" \
  --parameters location="${LOCATION}" deploymentMode="${DEPLOYMENT_MODE}" \
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
  --parameters location="${LOCATION}" deploymentMode="${DEPLOYMENT_MODE}" \
  --query "{state:properties.provisioningState, ws:properties.outputs.workspaceId.value, mode:properties.outputs.deploymentModeApplied.value}" \
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
echo "=================================================="
