#!/usr/bin/env bash
#
# safe_git_sync.sh (v2)
# 사용법: ./safe_git_sync.sh "커밋 메시지" [target-branch]
#
# v1 대비 추가로 해결한 엣지케이스:
#   1. pull 실패 시 원래 브랜치로 자동 복구 (trap 사용)
#   2. git 저장소가 아닌 폴더에서 실행 시 사전 안내 후 종료
#   3. commit 실패(훅 실패 등) 시 원인 안내
#   4. origin 리모트 자체가 없을 때 정확한 원인 안내
#   5. 최초 push 시 upstream(-u) 자동 설정
#   6. add 전에 민감 파일(.env 등) 및 대용량 파일 스테이징 여부 경고 + 확인

set -uo pipefail
# 주의: v1은 set -e를 썼지만, v2는 각 단계를 명시적으로 체크하고
# 실패 시 trap으로 복구 로직을 태워야 하므로 -e를 빼고 수동으로 제어합니다.

MSG=${1:-"auto: update code"}
TARGET_BRANCH=${2:-"main"}

# ── 0. 사전 확인 ──────────────────────────────────────────────
echo "=== 0. 사전 확인 ==="

# [엣지케이스 2] git 저장소인지 확인
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "❌ 현재 폴더는 git 저장소가 아닙니다."
  echo "👉 'git init' 으로 초기화하거나, 올바른 프로젝트 폴더에서 실행해주세요."
  exit 1
fi

CURRENT_BRANCH=$(git branch --show-current)
if [ -z "$CURRENT_BRANCH" ]; then
  echo "❌ 현재 브랜치를 확인할 수 없습니다. (detached HEAD 상태?)"
  exit 1
fi

# [엣지케이스 4] origin 리모트 존재 여부를 미리 확인해서 이후 메시지를 정확하게
HAS_ORIGIN=true
if ! git remote get-url origin >/dev/null 2>&1; then
  HAS_ORIGIN=false
  echo "⚠️  'origin' 리모트가 설정되어 있지 않습니다. (병합/푸시 단계가 제한됩니다)"
  echo "   나중에 연결하려면: git remote add origin <저장소 URL>"
fi

echo "현재 브랜치 : $CURRENT_BRANCH"
echo "대상 브랜치 : $TARGET_BRANCH"
echo "origin 존재 : $HAS_ORIGIN"

# [엣지케이스 1] pull/checkout 도중 실패하면 원래 브랜치로 자동 복귀
cleanup() {
  local exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    local now_branch
    now_branch=$(git branch --show-current 2>/dev/null || echo "")
    if [ "$now_branch" != "$CURRENT_BRANCH" ] && [ -n "$CURRENT_BRANCH" ]; then
      echo ""
      echo "🔧 비정상 종료 감지: '$now_branch' 브랜치에 남아있어 '$CURRENT_BRANCH'로 복구합니다."
      git checkout "$CURRENT_BRANCH" 2>/dev/null && echo "✅ 원래 브랜치로 복구 완료: $CURRENT_BRANCH"
    fi
  fi
}
trap cleanup EXIT

# ── 1. Git Add ───────────────────────────────────────────────
echo "=== 1. Git Add ==="

# [엣지케이스 6] 민감 파일 / 대용량 파일 사전 경고
SENSITIVE_PATTERN='\.env($|\.)|\.pem$|\.key$|id_rsa|credentials|secrets?\.(json|ya?ml)'
CANDIDATE_FILES=$(git status --porcelain | awk '{print $2}')

RISKY_FILES=$(echo "$CANDIDATE_FILES" | grep -E -i "$SENSITIVE_PATTERN" || true)
if [ -n "$RISKY_FILES" ]; then
  echo "⚠️  다음 파일들이 민감 정보를 포함할 수 있습니다:"
  echo "$RISKY_FILES" | sed 's/^/   - /'
  read -r -p "그래도 계속 진행할까요? (y/N): " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "🛑 사용자 취소로 종료합니다. .gitignore에 해당 파일을 추가하는 것을 권장합니다."
    exit 1
  fi
fi

LARGE_FILES=$(echo "$CANDIDATE_FILES" | xargs -I{} sh -c 'test -f "{}" && du -k "{}" 2>/dev/null' | awk '$1 > 10240 {print $2, "("$1"KB)"}')
if [ -n "$LARGE_FILES" ]; then
  echo "⚠️  10MB가 넘는 대용량 파일이 포함되어 있습니다:"
  echo "$LARGE_FILES" | sed 's/^/   - /'
  read -r -p "그래도 계속 진행할까요? (y/N): " CONFIRM_LARGE
  if [[ ! "$CONFIRM_LARGE" =~ ^[Yy]$ ]]; then
    echo "🛑 사용자 취소로 종료합니다. .gitignore 또는 Git LFS 사용을 권장합니다."
    exit 1
  fi
fi

git add .

# ── 2. Git Commit ────────────────────────────────────────────
echo "=== 2. Git Commit ==="
if git diff --cached --quiet; then
  echo "ℹ️  스테이징된 변경사항이 없어 커밋을 스킵합니다."
else
  # [엣지케이스 3] 커밋 실패(훅 실패, 빈 메시지 등) 원인 안내
  if [ -z "${MSG// /}" ]; then
    echo "❌ 커밋 메시지가 비어 있습니다. 커밋을 진행할 수 없습니다."
    exit 1
  fi

  if git commit -m "$MSG"; then
    echo "✅ 커밋 완료: $MSG"
  else
    echo "❌ 커밋이 실패했습니다. (pre-commit 훅 실패, GPG 서명 오류 등을 확인해주세요)"
    exit 1
  fi
fi

# ── 3. Git Merge ─────────────────────────────────────────────
echo "=== 3. Git Merge ($TARGET_BRANCH -> $CURRENT_BRANCH) ==="

if [ "$HAS_ORIGIN" = false ]; then
  echo "ℹ️  origin이 없어 병합을 스킵합니다."
elif [ "$CURRENT_BRANCH" == "$TARGET_BRANCH" ]; then
  echo "ℹ️  현재 브랜치와 대상 브랜치가 동일하여 병합을 스킵합니다."
else
  if git fetch origin "$TARGET_BRANCH"; then
    if git show-ref --verify --quiet "refs/remotes/origin/$TARGET_BRANCH"; then
      git checkout "$TARGET_BRANCH"

      # [엣지케이스 1] pull 실패 시 즉시 원래 브랜치로 복구 후 종료
      if ! git pull origin "$TARGET_BRANCH"; then
        echo "❌ '$TARGET_BRANCH' pull에 실패했습니다. (충돌 또는 로컬 변경사항 확인 필요)"
        git checkout "$CURRENT_BRANCH"
        echo "✅ 안전하게 '$CURRENT_BRANCH' 브랜치로 복구했습니다."
        exit 1
      fi

      git checkout "$CURRENT_BRANCH"

      if git merge "$TARGET_BRANCH" -m "merge: merge $TARGET_BRANCH into $CURRENT_BRANCH"; then
        echo "✅ 병합 완료"
      else
        echo "❌ 병합 충돌 발생! 자동으로 병합을 취소합니다 (merge --abort)."
        git merge --abort
        echo "👉 수동으로 'git merge $TARGET_BRANCH' 실행 후 충돌을 해결해주세요."
        exit 1
      fi
    fi
  else
    echo "⚠️  원격에서 '$TARGET_BRANCH' 브랜치를 가져오지 못했습니다. 병합을 스킵합니다."
  fi
fi

# ── 4. Git Push ───────────────────────────────────────────────
echo "=== 4. Git Push ==="

if [ "$HAS_ORIGIN" = false ]; then
  echo "❌ origin 리모트가 없어 푸시할 수 없습니다."
  echo "👉 'git remote add origin <저장소 URL>' 실행 후 다시 시도해주세요."
  exit 1
fi

# [엣지케이스 5] upstream이 없는 최초 push는 -u로 자동 설정
if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  PUSH_CMD=(git push origin "$CURRENT_BRANCH")
else
  echo "ℹ️  '$CURRENT_BRANCH'의 upstream이 설정되어 있지 않아 -u 옵션으로 최초 push합니다."
  PUSH_CMD=(git push -u origin "$CURRENT_BRANCH")
fi

# [엣지케이스 7] push 실패 원인을 로그에서 판별해 정확한 안내 제공
PUSH_LOG=$(mktemp)
if "${PUSH_CMD[@]}" 2>"$PUSH_LOG"; then
  echo "✅ 푸시 완료"
  rm -f "$PUSH_LOG"
else
  cat "$PUSH_LOG" >&2
  if grep -qiE "could not read username|could not read password|terminal prompts disabled|authentication failed" "$PUSH_LOG"; then
    echo "❌ 인증 실패입니다. GitHub 로그인 정보(자격 증명 또는 토큰)가 설정되어 있지 않거나 만료되었습니다."
    echo "👉 'git credential-manager' 로그인 상태를 확인하거나, Personal Access Token을 다시 발급해 설정해주세요."
  elif grep -qiE "permission denied|403" "$PUSH_LOG"; then
    echo "❌ 권한 거부입니다. 이 저장소에 대한 push 권한이 없습니다."
    echo "👉 저장소 소유자에게 협업자(collaborator) 권한을 요청하거나, 올바른 계정으로 로그인했는지 확인해주세요."
  elif grep -qiE "rejected|non-fast-forward|fetch first|behind" "$PUSH_LOG"; then
    echo "❌ 푸시 실패. 원격이 더 앞서있습니다. 'git pull --rebase' 후 다시 시도해주세요."
  elif grep -qiE "could not resolve host|network|timed out|unable to access" "$PUSH_LOG"; then
    echo "❌ 네트워크 오류입니다. 인터넷 연결 또는 프록시/방화벽 설정을 확인해주세요."
  else
    echo "❌ 푸시 실패. 위 원본 에러 메시지를 확인해주세요."
  fi
  rm -f "$PUSH_LOG"
  exit 1
fi

echo "=== 🎉 모든 작업이 완료되었습니다! ==="
