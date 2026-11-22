#!/usr/bin/env python3
"""远程配置中心签名工具（切片 7）。

签什么：除 `signature` 字段外的全部内容做规范 JSON（key 排序、无空格，
与 Dart 的 canonicalJson 逐字节一致）后 Ed25519 签名。
验签：客户端收到后先验签，验签通过才解析应用，验签失败直接丢弃。

只依赖 Python 标准库 + openssl 命令行（不引第三方包）。

用法：
  # 生成一对新密钥（私钥只存你指定的路径，绝不进仓库）：
  python3 sign.py generate-key --private ~/workspace/user/remote-config-private-key.pem
  # 输出 base64 公钥：把它编译进客户端（lib/brand/remote_config_keys.dart）。

  # 看一把私钥对应的公钥（换公钥时用）：
  python3 sign.py pubkey --key ~/workspace/user/remote-config-private-key.pem

  # 签一份配置（payload.json 是不含 signature 的配置内容）：
  python3 sign.py sign --key ~/workspace/user/remote-config-private-key.pem \
      --config payload.json --out client-config.json
  # --bump：沿用上一份信封的 config_version + 1（改配置必升版本，
  # 客户端只接受比本地缓存新的版本）：
  python3 sign.py sign --key ~/workspace/user/remote-config-private-key.pem \
      --config payload.json --out client-config.json --bump prev.json

  # 验一份信封（公钥是编译进客户端的那把 base64）：
  python3 sign.py verify --public <BASE64公钥> --envelope client-config.json

私钥保管（DEV-PLAN D14）：私钥由助手出、助手保管，各备两份离线备份，
密码分开保管；绝不进仓库、不进面板、不进 Worker 代码。
"""
import argparse
import base64
import json
import subprocess
import sys
import tempfile
import os

# Ed25519 SubjectPublicKeyInfo 的 DER 前缀（openssl pkey -pubout -outform DER
# 的前 12 字节）：302a 3005 06032b6570 0321 00，后面跟 32 字节原始公钥。
SPKI_PREFIX = bytes.fromhex('302a300506032b6570032100')


def canonical(obj) -> bytes:
    """规范 JSON：key 排序、无空格、UTF-8（与 Dart canonicalJson 一致）。"""
    return json.dumps(
        obj, sort_keys=True, separators=(',', ':'), ensure_ascii=False
    ).encode('utf-8')


def run(cmd, input_bytes=None):
    r = subprocess.run(cmd, input=input_bytes, capture_output=True)
    if r.returncode != 0:
        sys.exit(f"命令失败 {' '.join(cmd)}：{r.stderr.decode('utf-8', 'replace')}")
    return r.stdout


def cmd_generate_key(args):
    run(['openssl', 'genpkey', '-algorithm', 'ed25519',
         '-out', args.private])
    os.chmod(args.private, 0o600)
    pub = public_key_base64(args.private)
    print(f'私钥已生成：{args.private}（权限 600，只放离线处，绝不进仓库）')
    print(f'公钥（base64，编译进客户端 lib/brand/remote_config_keys.dart）：')
    print(pub)


def public_key_base64(private_path: str) -> str:
    der = run(['openssl', 'pkey', '-in', private_path,
               '-pubout', '-outform', 'DER'])
    if len(der) != 44 or der[:12] != SPKI_PREFIX:
        sys.exit('公钥 DER 格式不对，openssl 版本可能不认 Ed25519')
    return base64.b64encode(der[12:]).decode()


def cmd_pubkey(args):
    print(public_key_base64(args.key))


def sign_bytes(private_path: str, data: bytes) -> bytes:
    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(data)
        data_path = f.name
    try:
        with tempfile.NamedTemporaryFile(delete=False) as f:
            sig_path = f.name
        run(['openssl', 'pkeyutl', '-sign', '-inkey', private_path,
             '-rawin', '-in', data_path, '-out', sig_path])
        with open(sig_path, 'rb') as f:
            return f.read()
    finally:
        os.unlink(data_path)
        if os.path.exists(sig_path):
            os.unlink(sig_path)


def cmd_sign(args):
    with open(args.config, encoding='utf-8') as f:
        payload = json.load(f)
    if not isinstance(payload, dict):
        sys.exit('配置必须是 JSON 对象')
    payload.pop('signature', None)
    if args.bump:
        with open(args.bump, encoding='utf-8') as f:
            prev = json.load(f)
        if not isinstance(prev, dict) or not isinstance(
                prev.get('config_version'), int):
            sys.exit('--bump 的文件里没有 config_version（整数）')
        payload['config_version'] = prev['config_version'] + 1
    if not isinstance(payload.get('config_version'), int):
        sys.exit('配置里必须有 config_version（整数），改配置必升版本')
    sig = sign_bytes(args.key, canonical(payload))
    envelope = dict(payload)
    envelope['signature'] = base64.b64encode(sig).decode()
    with open(args.out, 'w', encoding='utf-8') as f:
        json.dump(envelope, f, ensure_ascii=False, indent=2)
        f.write('\n')
    print(f"已签名：config_version={payload['config_version']}，写到 {args.out}")


def cmd_verify(args):
    with open(args.envelope, encoding='utf-8') as f:
        envelope = json.load(f)
    if not isinstance(envelope, dict):
        sys.exit('信封必须是 JSON 对象')
    sig_b64 = envelope.get('signature')
    if not isinstance(sig_b64, str) or not sig_b64:
        sys.exit('信封里没有 signature 字段')
    payload = dict(envelope)
    payload.pop('signature', None)
    try:
        pub_raw = base64.b64decode(args.public)
        sig = base64.b64decode(sig_b64)
    except Exception as e:
        sys.exit(f'base64 解码失败：{e}')
    if len(pub_raw) != 32 or len(sig) != 64:
        sys.exit('公钥须 32 字节、签名须 64 字节')
    with tempfile.TemporaryDirectory() as d:
        pub_der = os.path.join(d, 'pub.der')
        with open(pub_der, 'wb') as f:
            f.write(SPKI_PREFIX + pub_raw)
        pub_pem = os.path.join(d, 'pub.pem')
        run(['openssl', 'pkey', '-pubin', '-inform', 'DER',
             '-in', pub_der, '-out', pub_pem])
        data_path = os.path.join(d, 'data.bin')
        with open(data_path, 'wb') as f:
            f.write(canonical(payload))
        sig_path = os.path.join(d, 'sig.bin')
        with open(sig_path, 'wb') as f:
            f.write(sig)
        r = subprocess.run(
            ['openssl', 'pkeyutl', '-verify', '-pubin', '-inkey', pub_pem,
             '-rawin', '-in', data_path, '-sigfile', sig_path],
            capture_output=True)
        if r.returncode != 0:
            sys.exit('验签失败：签名对不上（配置可能被改过，或公钥不对）')
    print(f"验签通过：config_version={payload.get('config_version')}")


def main():
    p = argparse.ArgumentParser(description='远程配置中心签名工具')
    sub = p.add_subparsers(dest='cmd', required=True)

    g = sub.add_parser('generate-key', help='生成一对 Ed25519 密钥')
    g.add_argument('--private', required=True, help='私钥保存路径（只放离线处）')
    g.set_defaults(func=cmd_generate_key)

    k = sub.add_parser('pubkey', help='看一把私钥对应的 base64 公钥')
    k.add_argument('--key', required=True, help='私钥路径')
    k.set_defaults(func=cmd_pubkey)

    s = sub.add_parser('sign', help='给一份配置签名，输出信封 JSON')
    s.add_argument('--key', required=True, help='私钥路径')
    s.add_argument('--config', required=True, help='不含 signature 的配置 JSON')
    s.add_argument('--out', required=True, help='输出的信封 JSON 路径')
    s.add_argument('--bump', help='上一份信封：沿用它的 config_version + 1')
    s.set_defaults(func=cmd_sign)

    v = sub.add_parser('verify', help='验一份信封的签名')
    v.add_argument('--public', required=True, help='base64 公钥（编译进客户端那把）')
    v.add_argument('--envelope', required=True, help='信封 JSON 路径')
    v.set_defaults(func=cmd_verify)

    args = p.parse_args()
    args.func(args)


if __name__ == '__main__':
    main()
