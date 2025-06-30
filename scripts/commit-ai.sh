S#!/bin/bash

# --- Configuration ---
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PROJECT_ROOT=$(dirname "$SCRIPT_DIR")
LOG_DIR="${PROJECT_ROOT}/docs/devlog"
TEMPLATE_FILE="${LOG_DIR}/_template.md"
TODAY=$(date +%Y-%m-%d)
LOG_FILE="${LOG_DIR}/${TODAY}.md"

# --- Main Logic ---
echo "🤖 AIによるコミットと日誌生成を開始します..."

# NEW: 未ステージの変更を確認し、ユーザーに追加を促す
if ! git diff --quiet; then
    echo "🔍 未ステージの変更が検出されました。"
    # ユーザーに変更内容を分かりやすく提示
    git status --short
    # 確認プロンプト
    read -p "👉 これらの変更をすべてステージングしますか？ (y/n) " -n 1 -r
    echo # 改行のため
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "✅ すべての変更をステージングします..."
        git add .
    else
        echo "ℹ️ ステージングはスキップされました。現在ステージング済みの変更のみがコミット対象になります。"
    fi
fi

# 1. Gitからコンテキストを収集
echo "🔍 Gitから情報を収集中..."
GIT_DIFF=$(git diff --staged)

if [ -z "$GIT_DIFF" ]; then
  echo "⚠️ ステージングされた変更がありません。'git add'でコミットしたい変更をステージングしてください。"
  exit 1
fi

CHANGED_FILES=$(git diff --staged --name-only | sed 's/^/  - /')
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# 2. テンプレートを読み込み、AIへのプロンプトを生成
TEMPLATE_CONTENT=$(sed "s/{{DATE}}/$TODAY/g" "$TEMPLATE_FILE")

AI_PROMPT=$(cat <<EOF
あなたは世界クラスのソフトウェアエンジニアリングアシスタントです。
以下の開発コンテキストを分析し、指定されたフォーマットでアウトプットを生成してください。

**重要: 出力フォーマット**
1行目: Conventional Commits形式のコミットメッセージのみ。
2行目: \`---LOG_SEPARATOR---\` という区切り文字のみ。
3行目以降: Markdown形式の開発日誌。開発日誌は、提供されたテンプレートの指示に従って記述してください。

---

### 開発コンテキスト (Development Context)
*   現在のブランチ: ${CURRENT_BRANCH}
*   変更されたファイル:
${CHANGED_FILES}
*   具体的な差分 (diff):
\`\`\`diff
${GIT_DIFF}
\`\`\`

---

### アウトプットのテンプレート (この下に生成してください)

(ここにコミットメッセージ)
---LOG_SEPARATOR---
${TEMPLATE_CONTENT}
EOF
)

# 3. ユーザーにプロンプトを提示し、AIの回答を待つ
echo "✅ AIへの指示プロンプトを生成しました。AIチャットに貼り付けてください。"
echo "---"
echo "$AI_PROMPT"
echo "---"
echo "👆 上記のプロンプトをAIに貼り付け、生成された全文を下に貼り付けてください。"
echo "   (貼り付けが終わったら、新しい行で Ctrl+D を押して入力を終了します)"

AI_RESPONSE=$(cat)

if [ -z "$AI_RESPONSE" ]; then
    echo "❌ 応答がありません。処理を中断します。"
    exit 1
fi

# 4. AIの応答をパースする
COMMIT_MSG=$(echo "$AI_RESPONSE" | sed -n '1p')
LOG_CONTENT=$(echo "$AI_RESPONSE" | sed -n '/---LOG_SEPARATOR---/,$p' | sed '1d')

if [ -z "$COMMIT_MSG" ] || [ -z "$LOG_CONTENT" ]; then
    echo "❌ AIの応答のパースに失敗しました。フォーマットを確認してください。"
    exit 1
fi

# 5. コミットと日誌の保存、プッシュを実行
echo "📝 開発日誌を保存します: ${LOG_FILE}"
echo "$LOG_CONTENT" > "$LOG_FILE"
git add "$LOG_FILE"

echo "💬 コミットを実行します (Message: $COMMIT_MSG)"
git commit -m "$COMMIT_MSG"

echo "🚀 リモートリポジトリにプッシュします..."
git push

echo "✅ 完了しました！"
