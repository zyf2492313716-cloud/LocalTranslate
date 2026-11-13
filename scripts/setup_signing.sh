#!/bin/bash
# 建一把本地自签名代码签名证书，放进独立钥匙串，供 build_app.sh 签名用。
#
# 为什么要这个：ad-hoc 签名（codesign -s -）每次重编译 cdhash 都会变，
# macOS 会把新二进制当成一个全新 App，之前批的辅助功能权限直接失效，
# 每次改完代码都得重新去系统设置里勾一遍。用固定身份的证书签名，
# 授权跟着 App 走，重编译不再掉权限。
#
# 证书放在单独的空口令钥匙串里，不碰系统登录钥匙串（那个要用户口令才能解锁）。
# 这个脚本可以反复跑，不会重复建证书。
set -euo pipefail

CERT_NAME="LocalTranslate Dev"
KC_NAME="LocalTranslate.keychain-db"
KC_PATH="$HOME/Library/Keychains/$KC_NAME"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERT_DIR="$ROOT/.signing"
FINGERPRINT_FILE="$CERT_DIR/cert-sha1.txt"

mkdir -p "$CERT_DIR"

echo "==> 准备签名钥匙串 $KC_PATH"
if [ ! -f "$KC_PATH" ]; then
    security create-keychain -p "" "$KC_PATH"
fi
security unlock-keychain -p "" "$KC_PATH"

DEFAULT_KC="$(security default-keychain -d user | tr -d '"')"
security list-keychains -d user -s "$DEFAULT_KC" "$KC_PATH"
# 这把钥匙串不许自动锁：锁过一次再解锁，私钥的 partition list 就失效，
# codesign 报 errSecInternalComponent，然后悄悄退回 ad-hoc 签名。
security set-keychain-settings "$KC_PATH" 2>/dev/null || true

# 存在性只能用 find-certificate 判断。
# 不能用 find-identity：它按「可信」过滤，自签名证书永远返回 0 条，
# 于是每跑一次就再导入一张，同名证书攒到两张，codesign 直接报 ambiguous。
EXISTING="$(security find-certificate -a -c "$CERT_NAME" -Z "$KC_PATH" 2>/dev/null | grep -c 'SHA-1 hash' || true)"
EXISTING="${EXISTING:-0}"
if [ "$EXISTING" -gt 0 ]; then
    echo "==> 证书已存在（${CERT_NAME}，$EXISTING 张）"
    if [ "$EXISTING" -gt 1 ]; then
        echo "  !! 同名证书不止一张，codesign 会报 ambiguous。删掉多余的，只留"
        echo "  !! .signing/cert-sha1.txt 里记着的那张："
        echo "     security find-certificate -a -c \"$CERT_NAME\" -Z \"$KC_PATH\""
        echo "     security delete-certificate -Z <要删的SHA1> \"$KC_PATH\""
    fi
else
    echo "==> 生成自签名证书: $CERT_NAME"
    cat > "$CERT_DIR/openssl.cnf" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT_NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CFG

    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
        -days 3650 -config "$CERT_DIR/openssl.cnf" -extensions ext 2>/dev/null

    openssl pkcs12 -export -out "$CERT_DIR/dev.p12" \
        -inkey "$CERT_DIR/key.pem" -in "$CERT_DIR/cert.pem" \
        -passout pass:localtranslate 2>/dev/null

    security import "$CERT_DIR/dev.p12" -k "$KC_PATH" -P localtranslate -A
    echo "  证书已生成并导入"
fi

# partition list 每次都要重设（原因见上）
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KC_PATH" >/dev/null 2>&1 || true

# 记下指纹：build_app.sh 按指纹签名，不靠名字（名字会撞）
FINGERPRINT="$(security find-certificate -a -c "$CERT_NAME" -Z "$KC_PATH" 2>/dev/null | grep 'SHA-1 hash' | head -1 | awk '{print $NF}')"
if [ -n "$FINGERPRINT" ]; then
    printf '%s\n' "$FINGERPRINT" > "$FINGERPRINT_FILE"
    echo "==> 签名身份指纹: $FINGERPRINT"
else
    echo "==> 没找到证书指纹"; exit 1
fi
