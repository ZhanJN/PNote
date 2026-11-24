#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Rebuild an "archive copy" of a release folder, then verify it file by file.

An archive copy contains exactly: pc/**, android/*.apk, and the two text docs
if they exist in the source root. The notes library is never copied.

Usage:
    python pack_archive.py <src> <dst>

Exit code 0 means: the destination was rebuilt from scratch and every file
matches the source by size and SHA-256.
"""
import hashlib
import os
import shutil
import sys

DOCS = ['使用说明.txt', '版本说明.txt']
DIRS = ['pc', 'android']


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def collect(root):
    """Return {relative posix path: absolute path} for files we want to keep."""
    out = {}
    for name in DIRS:
        folder = os.path.join(root, name)
        if not os.path.isdir(folder):
            sys.exit('missing source folder: %s' % folder)
        for dirpath, _dirnames, filenames in os.walk(folder):
            for filename in filenames:
                absolute = os.path.join(dirpath, filename)
                relative = os.path.relpath(absolute, root).replace(os.sep, '/')
                out[relative] = absolute
    for name in DOCS:
        absolute = os.path.join(root, name)
        if os.path.isfile(absolute):
            out[name] = absolute
    return out


def copy_tree(src_root, dst_root, mapping):
    if os.path.isdir(dst_root):
        shutil.rmtree(dst_root)
    for relative, absolute in sorted(mapping.items()):
        target = os.path.join(dst_root, relative.replace('/', os.sep))
        parent = os.path.dirname(target)
        if parent and not os.path.isdir(parent):
            os.makedirs(parent)
        shutil.copyfile(absolute, target)


def verify(dst_root, mapping):
    problems = []
    actual = set()
    for dirpath, _dirnames, filenames in os.walk(dst_root):
        for filename in filenames:
            absolute = os.path.join(dirpath, filename)
            actual.add(os.path.relpath(absolute, dst_root).replace(os.sep, '/'))
    expected = set(mapping)
    if expected != actual:
        problems.append('extra=%s missing=%s'
                        % (sorted(actual - expected), sorted(expected - actual)))
    for relative, source in mapping.items():
        target = os.path.join(dst_root, relative.replace('/', os.sep))
        if not os.path.isfile(target):
            continue
        if os.path.getsize(source) != os.path.getsize(target):
            problems.append('size differs: %s' % relative)
        elif sha256(source) != sha256(target):
            problems.append('sha differs: %s' % relative)
    return problems


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, dst = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    if not os.path.isdir(src):
        sys.exit('source not found: %s' % src)
    if os.path.abspath(src) == os.path.abspath(dst):
        sys.exit('source and destination are the same folder')
    mapping = collect(src)
    copy_tree(src, dst, mapping)
    problems = verify(dst, mapping)
    if problems:
        print('PACK FAILED')
        for line in problems:
            print(' -', line)
        sys.exit(1)
    app_so = os.path.join(dst, 'pc', 'data', 'app.so')
    apk = os.path.join(dst, 'android', 'PNote.apk')
    print('OK files=%d pc=%d android=%d app.so=%s apk=%s'
          % (len(mapping),
             sum(1 for k in mapping if k.startswith('pc/')),
             sum(1 for k in mapping if k.startswith('android/')),
             os.path.getsize(app_so) if os.path.isfile(app_so) else 'n/a',
             os.path.getsize(apk) if os.path.isfile(apk) else 'n/a'))


if __name__ == '__main__':
    main()
