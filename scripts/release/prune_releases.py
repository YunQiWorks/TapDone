#!/usr/bin/env python3
"""Keep the latest published release and explicitly archived releases; keep Git tags."""
import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def github(*args):
    return subprocess.check_output(['gh', 'api', *args], text=True)


def prune(repository, tag, version=None):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('仓库名称格式不正确。')
    if not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
        raise ValueError('发布标签格式不正确。')
    version_tag = 'v' + version if version else tag
    if not re.fullmatch(r'v\d+\.\d+\.\d+', version_tag):
        raise ValueError('安装包版本格式不正确。')
    archived = json.loads((ROOT / '.github/archived-releases.json').read_text())
    if not isinstance(archived, list) or not all(isinstance(value, str) and re.fullmatch(r'v\d+\.\d+\.\d+', value) for value in archived):
        raise ValueError('封存名单必须是版本标签字符串数组。')
    endpoint = f'repos/{repository}/releases'
    latest = json.loads(github(endpoint + '/latest'))
    if latest['tag_name'] != tag:
        raise RuntimeError('当前最新 Release 与本次发布不一致，停止清理。')
    assets = {asset['name'] for asset in latest['assets'] if asset['state'] == 'uploaded'}
    if not {f'TapDone-{version_tag}-universal.zip', 'SHA256SUMS', 'appcast.xml'} <= assets:
        raise RuntimeError('最新发布缺少完整附件，停止清理。')
    if tag in archived and version_tag != tag:
        raise RuntimeError('封存版本不能作为滚动 Release 入口。')
    for asset in latest['assets']:
        if asset['name'].startswith('TapDone-v') and asset['name'].endswith('-universal.zip') and asset['name'] != f'TapDone-{version_tag}-universal.zip':
            github('--method', 'DELETE', endpoint + '/assets/' + str(asset['id']))
            print('已删除旧安装包：' + asset['name'], flush=True)
    pages = json.loads(github('--paginate', '--slurp', endpoint + '?per_page=100'))
    keep = set(archived) | {tag}
    candidates = []
    for page in pages:
        for release in page:
            if release['draft'] or release['tag_name'] in keep:
                continue
            if release['immutable']:
                raise RuntimeError('旧发布已设为不可变，无法自动清理：' + release['tag_name'])
            candidates.append(release)
    for release in candidates:
        github('--method', 'DELETE', endpoint + '/' + str(release['id']))
        print('已删除旧 Release（保留源码标签）：' + release['tag_name'], flush=True)
    print('保留最新发布和封存版本：' + ', '.join(sorted(keep)), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--version')
    args = parser.parse_args()
    prune(args.repository, args.tag, args.version)
