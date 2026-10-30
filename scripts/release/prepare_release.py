#!/usr/bin/env python3
"""Build an ad-hoc signed app and prepare an EdDSA-signed TapDone release; publication is handled by CI.

Run only when publishing a version. Keys come from environment/CI secrets, never argv.
"""
import argparse
import base64
import hashlib
import html
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import format_datetime

SPARKLE_VERSION = "2.10.1"
SPARKLE_SHA256 = "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a"
NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", NS)
ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / ".release"


def required(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError("缺少发布配置：" + name)
    return value


def run(command, *, log=None, stdin=None, sensitive=False):
    # Never echo argv or signing key input.
    result = subprocess.run([str(value) for value in command], input=stdin, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if log:
        Path(log).write_text(result.stdout)
    if result.returncode:
        detail = "（敏感工具输出已隐藏）" if sensitive else ("，见 " + str(log) if log else "")
        raise RuntimeError(Path(str(command[0])).name + " 执行失败" + detail)
    return result.stdout


def download(url, *, allow_missing=False):
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        if allow_missing and error.code == 404:
            return None
        raise


def sign(tool, private_key, path, *, verify=False, signature_only=False):
    command = [tool, "--ed-key-file", "-"]
    if verify:
        command.append("--verify")
    if signature_only:
        command.append("-p")
    command.append(path)
    return run(command, stdin=private_key + "\n", sensitive=True).strip()


def prepare(tag, build):
    if sys.platform != "darwin":
        raise RuntimeError("发布脚本需要 macOS。")
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag) or build < 1:
        raise RuntimeError("发布标签需为 v主版本.次版本.修订号，构建号需为正整数。")
    version = tag[1:]
    public_key = required("SPARKLE_PUBLIC_KEY")
    private_key = required("SPARKLE_PRIVATE_KEY")
    try:
        if len(base64.b64decode(public_key, validate=True)) != 32:
            raise ValueError()
        if len(base64.b64decode(private_key, validate=True)) not in (32, 64, 96):
            raise ValueError()
    except ValueError:
        raise RuntimeError("Sparkle 公钥或私钥的编码格式不正确。") from None
    repository = os.environ.get("GITHUB_REPOSITORY", "YunQiWorks/TapDone")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise RuntimeError("仓库名称格式不正确。")
    owner, repository_name = repository.split("/")
    feed_url = "https://" + owner.lower() + ".github.io/" + repository_name + "/appcast.xml"
    WORK.mkdir(exist_ok=True)
    tool_archive = WORK / "Sparkle.zip"
    tool_archive.write_bytes(download("https://github.com/sparkle-project/Sparkle/releases/download/" + SPARKLE_VERSION + "/Sparkle-for-Swift-Package-Manager.zip"))
    if hashlib.sha256(tool_archive.read_bytes()).hexdigest() != SPARKLE_SHA256:
        raise RuntimeError("Sparkle 工具包 SHA-256 不匹配。")
    tools = WORK / "sparkle"
    run(["ditto", "-x", "-k", tool_archive, tools])
    sign_tool = tools / "bin/sign_update"
    sign_tool.chmod(sign_tool.stat().st_mode | 0o100)
    previous = download(feed_url, allow_missing=True)
    if previous is not None:
        old_feed = WORK / "previous-appcast.xml"
        old_feed.write_bytes(previous)
        sign(sign_tool, private_key, old_feed, verify=True)
        channel = ET.fromstring(previous).find("channel")
        if channel is None:
            raise RuntimeError("现有 appcast 缺少 channel。")
        for item in channel.findall("item"):
            old_build = item.findtext("{" + NS + "}version")
            old_version = item.findtext("{" + NS + "}shortVersionString")
            if old_build is None or not old_build.isdigit() or build <= int(old_build):
                raise RuntimeError("新构建号必须高于更新源中的所有构建号。")
            if old_version and tuple(map(int, version.split("."))) <= tuple(map(int, old_version.split("."))):
                raise RuntimeError("新版本号必须高于已发布版本。")
    else:
        channel = ET.parse(ROOT / "updates/appcast.xml").getroot().find("channel")
    if channel is None:
        raise RuntimeError("appcast 模板缺少 channel。")
    print("发布配置和更新源检查完成，开始构建 " + version, flush=True)
    archive = WORK / "SideTap.xcarchive"
    if archive.exists():
        shutil.rmtree(archive)
    # No provisioning profile, Apple account, Developer ID or notarization needed.
    # Ad-hoc signatures have no Team ID: disable hardened runtime/library validation
    # so the application can load the bundled Sparkle framework.
    run(["xcodebuild", "archive", "-project", ROOT / "SideTap.xcodeproj", "-scheme", "SideTap",
         "-configuration", "Release", "-destination", "generic/platform=macOS", "-archivePath", archive,
         "-derivedDataPath", WORK / "DerivedData", "-clonedSourcePackagesDirPath", WORK / "SourcePackages",
         "-onlyUsePackageVersionsFromResolvedFile", "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=-",
         "DEVELOPMENT_TEAM=", "ENABLE_HARDENED_RUNTIME=NO", "CODE_SIGN_ENTITLEMENTS=",
         "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO", "MARKETING_VERSION=" + version,
         "CURRENT_PROJECT_VERSION=" + str(build), "SPARKLE_PUBLIC_KEY=" + public_key,
         "SIDETAP_UPDATE_FEED_URL=" + feed_url], log=WORK / "archive.log")
    export = WORK / "export"
    if export.exists():
        shutil.rmtree(export)
    export.mkdir()
    app = export / "TapDone.app"
    run(["ditto", archive / "Products/Applications/TapDone.app", app])
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("SUPublicEDKey") != public_key or info.get("SUFeedURL") != feed_url:
        raise RuntimeError("应用中的公钥或更新地址与发布配置不一致。")
    if not (app / "Contents/Helpers/sidetap").is_file():
        raise RuntimeError("应用缺少内置 CLI。")
    if not (app / "Contents/Frameworks/Sparkle.framework").is_dir():
        raise RuntimeError("应用缺少 Sparkle 框架。")
    # Xcode signs embedded code before the outer app. Verify the resulting bundle;
    # this checks integrity, not Apple trust or notarization.
    run(["codesign", "--verify", "--deep", "--strict", app], log=WORK / "codesign.log")
    dist = WORK / "dist"
    dist.mkdir(exist_ok=True)
    zip_name = "TapDone-" + tag + "-universal.zip"
    package = dist / zip_name
    package.unlink(missing_ok=True)
    run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, package])
    signature = sign(sign_tool, private_key, package, signature_only=True)
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise RuntimeError("Sparkle 未返回有效的更新包签名。")
    run(["xcrun", "swift", ROOT / "scripts/release/verify_signature.swift", package, public_key, signature])
    note_file = ROOT / "release-notes" / (version + ".md")
    notes = note_file.read_text() if note_file.exists() else "TapDone " + version
    (WORK / "release-notes.md").write_text(notes)
    item = ET.Element("item")
    ET.SubElement(item, "title").text = "TapDone " + version
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, "{" + NS + "}version").text = str(build)
    ET.SubElement(item, "{" + NS + "}shortVersionString").text = version
    ET.SubElement(item, "{" + NS + "}minimumSystemVersion").text = "13.0.0"
    ET.SubElement(item, "description").text = "<pre>" + html.escape(notes) + "</pre>"
    ET.SubElement(item, "enclosure", {"url": "https://github.com/" + repository + "/releases/download/" + tag + "/" + zip_name,
                                    "length": str(package.stat().st_size), "type": "application/octet-stream",
                                    "{" + NS + "}edSignature": signature})
    channel.insert(0, item)
    for old in channel.findall("item")[10:]:
        channel.remove(old)
    feed_root = ET.Element("rss", {"version": "2.0"})
    feed_root.append(channel)
    site = WORK / "site"
    site.mkdir(exist_ok=True)
    feed = site / "appcast.xml"
    ET.indent(feed_root)
    ET.ElementTree(feed_root).write(feed, encoding="utf-8", xml_declaration=True)
    sign(sign_tool, private_key, feed)
    sign(sign_tool, private_key, feed, verify=True)
    (site / "index.html").write_text('<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>TapDone</title><h1>即达 · TapDone</h1><p><a href="https://github.com/' + html.escape(repository) + '/releases">下载与更新说明</a></p></html>')
    (dist / "SHA256SUMS").write_text(hashlib.sha256(package.read_bytes()).hexdigest() + "  " + zip_name + "\n")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a") as stream:
            stream.write("zip_name=" + zip_name + "\n")
    print("Ad-hoc 应用、EdDSA 更新包与订阅文件已准备完成：" + str(package))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--build", type=int, required=True)
    args = parser.parse_args()
    try:
        prepare(args.tag, args.build)
    except Exception as error:
        print("发布准备失败：" + str(error), file=sys.stderr)
        sys.exit(1)
