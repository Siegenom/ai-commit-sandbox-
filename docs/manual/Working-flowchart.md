## プロジェクト構成と処理フロー

このドキュメントは、AIコミット＆日誌生成ツールの全ファイルの役割と、それらがどのように連携して動作するかを解説します。

### ■ 主要ファイルとフォルダの役割

| ファイル/フォルダ | 役割 |
| :--- | :--- |
| **`scripts/commit-ai.ps1`** | **メインスクリプト。** ユーザーが実行する中心的なファイル。Git情報の収集、AI応答のキャッシュ確認、API呼び出しの指示、最終的なコミットまで、全体の処理フローを制御します。 |
| **`scripts/manage-prompt.ps1`** | **設定管理スクリプト。** 対話形式で`prompt-config.json`の内容を安全に編集します。お気に入りの設定を「プリセット」として保存・読込する機能も持ちます。 |
| **`scripts/api_adapters/`** | **API連携スクリプト群。** `invoke-gemini-api.ps1`などがここに配置されます。メインスクリプトから渡されたプロンプトを、各AIサービス（Geminiなど）が要求する形式に整形し、実際にAPI通信を行う責務を担います。 |
| `scripts/prompt-config.json` | **ユーザー設定ファイル。** AIのペルソナやタスク指示など、ユーザーが自由にカスタマイズする設定が保存されます。このファイルは`.gitignore`で管理対象外とすべきです。 |
| `scripts/prompt-config.default.json` | **初期設定ファイル。** `prompt-config.json`が存在しない場合にコピーされたり、設定を初期状態に戻したりする際のテンプレートとなります。 |
| **`scripts/presets/`** | **プリセット保存フォルダ。** `manage-prompt.ps1`で保存した、ユーザー独自の設定プリセット（`.json`形式）が格納されます。このフォルダも`.gitignore`で管理対象外とするのが適切です。 |
| `scripts/.last_goal.txt` | **履歴ファイル。** `commit-ai.ps1`で前回入力された「主な目標」を一時的に保存します。 |
| `scripts/.ai_cache.json` | **キャッシュファイル。** 一度APIから取得したAIの応答を保存します。「同じ差分」と「同じ目標」の組み合わせの場合は、APIを呼び出さず、このキャッシュを再利用してトークン消費を節約します。 |
| **`docs/devlog/`** | **開発日誌出力先。** AIが生成した日誌がMarkdownファイルとして保存されます。プロジェクトの成果物であり、ツール自体のソースコードとは分けるため、`.gitignore`で管理対象外とすることが推奨されます。 |

### ■ 全体処理フロー図

```mermaid
graph TD
    subgraph "Phase 1: ユーザー実行 & モード判定"
        A(ユーザーが commit-ai.ps1 を実行) --> B{実行時パラメータは？};
        B -- "-Debug" --> C[デバッグモード];
        B -- "-DryRun" --> D[ドライランモード];
        B -- "パラメータなし" --> E[通常モード];
        C --> F[サンプル差分データを使用];
        D --> G[日誌は一時フォルダへ<br>コミットは--dry-run];
        E --> H[Gitから実際の差分を取得];
    end

    subgraph "Phase 2: コンテキスト収集とキャッシュ確認"
        F --> I{目標入力 & キャッシュキー生成};
        H --> I;
        I --> J["scripts/.last_goal.txt<br>(目標履歴)"];
        I --> K{キャッシュは存在するか？};
        K -- "Yes" --> L["scripts/.ai_cache.json<br>から応答を読み込む"];
        K -- "No" --> M[API呼び出し準備];
    end

    subgraph "Phase 3: API連携 (キャッシュがない場合)"
        M --> N["scripts/prompt-config.json<br>からAI設定を読み込む"];
        M --> O[プロンプトJSONを構築];
        O --> P[invoke-gemini-api.ps1 を呼び出す];
        P -- "リトライ処理(50x系)" --> Q((🤖 Gemini API));
        Q --> P;
        P --> R[応答をキャッシュに保存<br>scripts/.ai_cache.json];
        R --> S[AI応答を取得];
    end

    subgraph "Phase 4: 応答の表示と最終処理"
        L --> T{AI応答をパース};
        S --> T;
        T --> U[コミットメッセージと日誌内容を表示];
        U --> V{"ユーザー確認<br>(コミット/編集/中止)"};
        V -- "コミット実行" --> W{モードに応じた処理};
        W -- "DryRunモード" --> X[--dry-runでコミット実行<br>一時ファイルを削除];
        W -- "通常モード" --> Y[通常のコミットとプッシュ];
        W -- "Debugモード(単体)" --> Z([安全に終了]);
    end

    classDef userAction fill:#fff2cc,stroke:#333,stroke-width:2px,color:#333;
    classDef scriptAction fill:#e6f0ff,stroke:#333,stroke-width:1px,color:#333;
    classDef fileIO fill:#e6ffe6,stroke:#333,stroke-width:1px,color:#333;
    classDef decision fill:#ffebf0,stroke:#333,stroke-width:1px,color:#333;
    classDef api fill:#f0e6ff,stroke:#333,stroke-width:2px,color:#333;

    class A,V userAction;
    class B,K,W,T decision;
    class C,D,E,F,G,H,I,M,O,P,S,U,X,Y,Z scriptAction;
    class J,L,N,R fileIO;
    class Q api;
```

---
### ■ 全体処理フロー図

```mermaid
graph LR
    subgraph "生成物"
        direction TB
        O1["O1: docs/devlog/*.md<br>(開発日誌)"];
    end

    subgraph "設定・データファイル"
        direction TB
        F1["F1: prompt-config.json<br>(ユーザー設定)"];
        F2["F2: prompt-config.default.json<br>(初期設定)"];
        F3["F3: presets/*.json<br>(設定プリセット群)"];
        F4["F4: ai_cache.json<br>(AI応答キャッシュ)"];
        F5["F5: last_goal.txt<br>(目標入力履歴)"];
    end
    
    subgraph "実行スクリプト"
        direction TB
        S1["S1: commit-ai.ps1<br>(メイン処理)"];
        S2["S2: manage-prompt.ps1<br>(設定管理)"];
        S3["S3: invoke-gemini-api.ps1<br>(API Adapter)"];
    end

    subgraph "外部サービス"
        direction TB
        E1(("E1: 🤖 Gemini API"));
    end

    F1 ~~~ O1;
    S3 ~~~ F1

%% linkStyle 2 stroke:#0000FF,stroke-width:2px 
%% linkStyle 3 stroke:#000FF,stroke-width:2px
%% linkStyle 4 stroke:#F000FF,stroke-width:2px

    S1 --> F1; 
    S1<--> F4;
    S1<--> F5;
    S1 -- "実行" --> S3;
    S1 --> O1;


    S2 <--> F3; 
    S2 <--> F1; 
    S2 --> F2; 

%%    S2 -- "(読込/書込)" --> F1; 


    S3 -- "データ" --> E1;

    classDef userAction fill:#fff2cc,stroke:#333,stroke-width:2px,color:#333;
    classDef scriptAction fill:#e6f0ff,stroke:#333,stroke-width:1px,color:#333;
    classDef fileIO fill:#e6ffe6,stroke:#333,stroke-width:1px,color:#333;
    classDef decision fill:#ffebf0,stroke:#333,stroke-width:1px,color:#333;
    classDef api fill:#f0e6ff,stroke:#333,stroke-width:2px,color:#333;

    class A,V userAction;
    class B,K,W,T decision;
    class C,D,E,F,G,H,I,M,O,P,S,U,X,Y,Z scriptAction;
    class J,L,N,R fileIO;
    class Q api;
```
```mermaid
flowchart LR
a1[a-1] --> a2[a-2] --> a3[a-3] --> a4[a-4]
b1(b-1) --> b2(b-2) --> b3(b-3) --> b4(b-4)

a1 --> b2
```