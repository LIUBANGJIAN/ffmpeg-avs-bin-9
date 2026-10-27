#!/usr/bin/env bash
# ==============================================================================
# 校验 env.sh 里所有依赖地址是否可达。
# 目的：CI 一次全量要几十分钟，别让一个拼错的 URL 把四十分钟烧掉。
# 用法： ./scripts/verify-urls.sh
# ==============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
. "$HERE/env.sh"

fail=0
printf '%-10s %-6s %s\n' "NAME" "CODE" "URL"
printf '%s\n' "----------------------------------------------------------------------"

for line in "${DEPS[@]}"; do
  IFS='|' read -r name kind url ref <<< "$line"

  if [ "$kind" = "git" ]; then
    if ref_branch_ok=$(git ls-remote --exit-code "$url" "$ref" 2>/dev/null) && [ -n "$ref_branch_ok" ]; then
      printf '%-10s %-6s %s (%s)\n' "$name" "GIT" "$url" "$ref"
    else
      printf '%-10s %-6s %s (%s)\n' "$name" "FAIL" "$url" "$ref"
      fail=$((fail+1))
    fi
    continue
  fi

  # 直连优先，失败再走本机代理（国内网络下 GitHub 的连通性是会来回变的）
  code=$(curl -sIL -o /dev/null -w '%{http_code}' -m 25 \
              --retry 1 --connect-timeout 10 "$url" 2>/dev/null)
  chan=""
  if [ "$code" != "200" ] && [ "$code" != "206" ] && [ -n "${PROXY:-}" ]; then
    code=$(curl -sIL -x "$PROXY" -o /dev/null -w '%{http_code}' -m 25 \
                --connect-timeout 10 "$url" 2>/dev/null)
    chan="(proxy)"
  fi
  printf '%-10s %-6s %s %s\n' "$name" "$code" "$url" "$chan"
  case "$code" in
    200|206) ;;
    *) fail=$((fail+1)) ;;
  esac
done

printf '%s\n' "----------------------------------------------------------------------"
if [ "$fail" -gt 0 ]; then
  printf '\n\033[1;31m%d 个地址不可达，先修 env.sh\033[0m\n' "$fail"
  exit 1
fi
printf '\n\033[1;32m全部可达\033[0m\n'
