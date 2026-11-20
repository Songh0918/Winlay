#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/winlay-publish-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/project/scripts" "$WORK/project/Winlay" "$WORK/bin" "$WORK/sparkle/bin"
cp "$ROOT/scripts/publish-beta.sh" "$WORK/project/scripts/"
cp "$ROOT/Winlay/Info.plist" "$WORK/project/Winlay/"
export TEST_LOG="$WORK/actions.log" TEST_FEED_SHA=original-feed-sha
cat > "$WORK/bin/git" <<'SH'
#!/bin/bash
case "$*" in
  *rev-parse\ --show-toplevel*) echo "$TEST_PROJECT";;
  *status\ --porcelain*) :;;
  *rev-parse\ HEAD*) echo 0123456789abcdef0123456789abcdef01234567;;
  *) exit 1;;
esac
SH
cat > "$WORK/bin/gh" <<'SH'
#!/bin/bash
set -euo pipefail
echo "$*" >> "$TEST_LOG"
case "$*" in
  'auth status') exit 0;;
  'api repos/'*'/git/commits/'*) exit 0;;
  'release view '*) exit 1;;
  'api repos/'*'/git/ref/tags/'*) exit 1;;
  'api repos/'*'/contents/appcast.xml?ref='*)
    [[ "${TEST_FETCH_FAILURE:-0}" != 1 ]] || exit 1
    python3 -c 'import base64,json; x=b"<rss xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\"><channel><item><sparkle:version>14</sparkle:version></item></channel></rss>"; print(json.dumps({"sha":"original-feed-sha","content":base64.b64encode(x).decode()}))';;
  'release create '*)
    case "$*" in *appcast.xml*) :;; *) exit 1;; esac
    [[ "${TEST_UPLOAD_FAILURE:-0}" != 1 ]];;
  'api --method PUT '*)
    while [[ "$1" != '--input' ]]; do shift; done
    python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["sha"] == "original-feed-sha"' "$2"
    [[ "${TEST_CONFLICT:-0}" != 1 ]];;
  *) echo "unexpected gh command: $*" >&2; exit 1;;
esac
SH
cat > "$WORK/project/scripts/build-app.sh" <<'SH'
#!/bin/bash
mkdir -p "$1"
printf 'test-archive' > "$1/Winlay-macos-universal.zip"
SH
cat > "$WORK/sparkle/bin/generate_keys" <<'SH'
#!/bin/bash
echo 'kiCGgDJPVCMJyEJctS4x83EYcoOV6I+5nzUD85AfRHw='
SH
cat > "$WORK/sparkle/bin/generate_appcast" <<'SH'
#!/bin/bash
feed="${!#}"
cat > "$feed/appcast.xml" <<'XML'
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>15</sparkle:version><enclosure url="https://github.com/Songh0918/Winlay/releases/download/v15-beta1/Winlay-v15-beta1.zip" length="12" sparkle:edSignature="test-signature"/></item></channel></rss>
XML
SH
cat > "$WORK/sparkle/bin/sign_update" <<'SH'
#!/bin/bash
[[ "${TEST_BAD_SIGNATURE:-0}" != 1 ]]
SH
chmod +x "$WORK/bin/"* "$WORK/sparkle/bin/"*
export PATH="$WORK/bin:$PATH" WINLAY_SPARKLE_DIR="$WORK/sparkle" TEST_PROJECT="$WORK/project"

bash "$WORK/project/scripts/publish-beta.sh" v15-beta1 1.5 15 > "$WORK/success.log"
grep -q '已发布测试更新' "$WORK/success.log"
grep -q 'release create .*appcast.xml' "$TEST_LOG"
: > "$TEST_LOG"
if TEST_BAD_SIGNATURE=1 bash "$WORK/project/scripts/publish-beta.sh" v15-beta1 1.5 15 > "$WORK/bad.log" 2>&1; then
  echo '签名失败时不能发布。' >&2; exit 1
fi
if grep -q '^release create ' "$TEST_LOG"; then echo '签名失败后仍执行了发布。' >&2; exit 1; fi
: > "$TEST_LOG"
if TEST_FETCH_FAILURE=1 bash "$WORK/project/scripts/publish-beta.sh" v15-beta1 1.5 15 > "$WORK/fetch.log" 2>&1; then
  echo '读取更新清单失败时不能发布。' >&2; exit 1
fi
if grep -q '^release create ' "$TEST_LOG"; then echo '读取清单失败后仍执行了发布。' >&2; exit 1; fi
: > "$TEST_LOG"
if TEST_UPLOAD_FAILURE=1 bash "$WORK/project/scripts/publish-beta.sh" v15-beta1 1.5 15 > "$WORK/upload.log" 2>&1; then
  echo '上传失败时不能更新清单。' >&2; exit 1
fi
if grep -q '^api --method PUT ' "$TEST_LOG"; then echo '上传失败后仍尝试更新清单。' >&2; exit 1; fi
: > "$TEST_LOG"
if TEST_CONFLICT=1 bash "$WORK/project/scripts/publish-beta.sh" v15-beta1 1.5 15 > "$WORK/conflict.log" 2>&1; then
  echo '更新清单发生并发修改时不能覆盖。' >&2; exit 1
fi
grep -q '发布附件中保留了可用于恢复的 appcast.xml' "$WORK/conflict.log"
echo '通过：本机签名发布、签名或网络失败拦截、清单并发冲突与恢复附件。'
