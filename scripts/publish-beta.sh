#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO=Songh0918/Winlay
FEED_BRANCH=winlay-updates-beta
TAG="${1:-}"
VERSION="${2:-}"
BUILD="${3:-}"
if [[ ! "$TAG" =~ ^v[0-9]+([.][0-9]+)*-beta[0-9]+$ || ! "$VERSION" =~ ^[0-9]+([.][0-9]+){0,2}$ || ! "$BUILD" =~ ^[0-9]+$ ]]; then
  echo '用法：bash scripts/publish-beta.sh v15-beta1 1.5 15' >&2
  exit 1
fi
command -v gh >/dev/null || { echo '需要先安装 GitHub CLI 并登录。' >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo '需要先运行 gh auth login 登录 GitHub。' >&2; exit 1; }
git -C "$ROOT" rev-parse --show-toplevel >/dev/null 2>&1 || { echo '需要在 Git 仓库副本中发布。' >&2; exit 1; }
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] || { echo '请先提交或处理工作区修改，确保发布包与源码一致。' >&2; exit 1; }
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
gh api "repos/$REPO/git/commits/$COMMIT" >/dev/null || { echo '当前提交尚未推送到 GitHub。' >&2; exit 1; }
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo '该测试版已存在，不会覆盖。' >&2; exit 1
fi
if gh api "repos/$REPO/git/ref/tags/$TAG" >/dev/null 2>&1; then
  echo '该标签已存在，不会复用已有标签。' >&2; exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/winlay-beta.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SPARKLE_DIR="${WINLAY_SPARKLE_DIR:-$WORK/sparkle}"
if [[ ! -x "$SPARKLE_DIR/bin/generate_appcast" ]]; then
  mkdir -p "$SPARKLE_DIR"
  curl -fsSL --retry 3 https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz -o "$WORK/sparkle.tar.xz"
  printf '%s  %s\n' 1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27 "$WORK/sparkle.tar.xz" | shasum -a 256 -c
  tar -xJf "$WORK/sparkle.tar.xz" -C "$SPARKLE_DIR"
fi
PUBLIC_KEY="$("$SPARKLE_DIR/bin/generate_keys" --account com.songh.winlay -p)"
EXPECTED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT/Winlay/Info.plist")"
[[ "$PUBLIC_KEY" == "$EXPECTED_KEY" ]] || { echo '钥匙串中的更新密钥与应用公钥不匹配。' >&2; exit 1; }

mkdir -p "$WORK/feed"
gh api "repos/$REPO/contents/appcast.xml?ref=$FEED_BRANCH" > "$WORK/feed-response.json"
python3 - "$WORK/feed-response.json" "$WORK/feed/appcast.xml" "$WORK/feed-sha" <<'PY'
import base64, json, pathlib, sys
response = json.loads(pathlib.Path(sys.argv[1]).read_text())
pathlib.Path(sys.argv[2]).write_bytes(base64.b64decode(response['content'], validate=False))
pathlib.Path(sys.argv[3]).write_text(response['sha'])
PY
OLD_SHA="$(cat "$WORK/feed-sha")"
export WINLAY_FEED_FILE="$WORK/feed/appcast.xml" WINLAY_RELEASE_BUILD="$BUILD"
python3 -c 'import os,xml.etree.ElementTree as e; root=e.parse(os.environ["WINLAY_FEED_FILE"]); versions=[int(x.text) for x in root.findall(".//{http://www.andymatuschak.org/xml-namespaces/sparkle}version")]; assert not versions or int(os.environ["WINLAY_RELEASE_BUILD"]) > max(versions), "构建号必须大于现有测试版"'

WINLAY_SKIP_DMG=1 WINLAY_SPARKLE_DIR="$SPARKLE_DIR" WINLAY_VERSION="$VERSION" WINLAY_BUILD_NUMBER="$BUILD" bash "$ROOT/scripts/build-app.sh" "$WORK/build"
cp "$WORK/build/Winlay-macos-universal.zip" "$WORK/feed/Winlay-$TAG.zip"
"$SPARKLE_DIR/bin/generate_appcast" --account com.songh.winlay --maximum-deltas 0 --maximum-versions 0 --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" "$WORK/feed"
export WINLAY_RELEASE_TAG="$TAG" WINLAY_RELEASE_REPO="$REPO"
SIGNATURE="$(python3 - <<'PY'
import os, pathlib, sys, xml.etree.ElementTree as ET
sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
root = ET.parse(os.environ['WINLAY_FEED_FILE'])
items = [item for item in root.findall('.//item') if item.findtext(sparkle + 'version') == os.environ['WINLAY_RELEASE_BUILD']]
if len(items) != 1:
    sys.exit('生成的更新清单缺少唯一的新版本。')
enclosure = items[0].find('enclosure')
name = 'Winlay-' + os.environ['WINLAY_RELEASE_TAG'] + '.zip'
expected = 'https://github.com/' + os.environ['WINLAY_RELEASE_REPO'] + '/releases/download/' + os.environ['WINLAY_RELEASE_TAG'] + '/' + name
if enclosure is None or enclosure.get('url') != expected or enclosure.get('length') != str(pathlib.Path(os.environ['WINLAY_FEED_FILE']).with_name(name).stat().st_size) or not enclosure.get(sparkle + 'edSignature'):
    sys.exit('生成的更新清单与安装包不一致。')
print(enclosure.get(sparkle + 'edSignature'))
PY
)"
"$SPARKLE_DIR/bin/sign_update" --account com.songh.winlay --verify "$WORK/feed/Winlay-$TAG.zip" "$SIGNATURE"
(cd "$WORK/feed" && shasum -a 256 "Winlay-$TAG.zip" > SHA256SUMS)
gh release create "$TAG" "$WORK/feed/Winlay-$TAG.zip" "$WORK/feed/SHA256SUMS" "$WORK/feed/appcast.xml" --repo "$REPO" --target "$COMMIT" --prerelease --title "Winlay $TAG" --notes 'Winlay 测试更新。'

export OLD_SHA WINLAY_FEED_FILE
python3 -c 'import base64,json,os; print(json.dumps({"message":"Update beta appcast", "branch":"winlay-updates-beta", "sha":os.environ["OLD_SHA"], "content":base64.b64encode(open(os.environ["WINLAY_FEED_FILE"],"rb").read()).decode()}))' > "$WORK/feed-request.json"
if ! gh api --method PUT "repos/$REPO/contents/appcast.xml" --input "$WORK/feed-request.json" >/dev/null; then
  echo '测试版已发布，但更新清单未更新；发布附件中保留了可用于恢复的 appcast.xml。' >&2
  exit 1
fi
echo "已发布测试更新 ${TAG}；私钥保留在本机钥匙串。"
