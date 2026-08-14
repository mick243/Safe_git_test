#!/usr/bin/env bash
# 15MB 더미 바이너리 파일 생성 (safe_git_sync_v2.sh의 대용량 파일 감지 테스트용)
# 사용법: bash generate_large_file.sh
dd if=/dev/zero of=large_asset.bin bs=1M count=15
echo "생성 완료: large_asset.bin (15MB)"
