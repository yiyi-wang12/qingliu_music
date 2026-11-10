#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
音乐服务器 —— 单文件、零第三方依赖。

运行：
    python main.py

目录结构（都在本文件同级）：
    main.py
    setting.json     端口等配置（首次运行自动生成）
    user.json        用户账号（pbkdf2 哈希，首次运行生成默认账号）
    library.json     收藏 / 歌单（首次运行自动生成）
    music/           音乐文件（递归扫描）
    lrc/             歌词文件（递归扫描）
    images/          封面图片（递归扫描，按歌曲名匹配）

账号管理：
    python main.py user list
    python main.py user add <用户名> <密码>
    python main.py user del <用户名>
    python main.py user passwd <用户名> <新密码>

接口：
    GET  /api/ping                     探活（登录前可用）
    POST /api/login                    {username, password} -> {token}
    GET  /api/config                   客户端分块大小等配置
    GET  /api/songs                    全部歌曲
    GET  /api/stream/<id>?token=       音频流（支持 Range）
    GET  /api/lrc/<id>?token=          歌词文本
    GET  /api/cover/<id>?token=        封面图片
    GET  /api/library                  收藏 + 歌单
    POST /api/favorites/toggle         {song_id}
    POST /api/favorites/batch          {song_ids: [...], action: add|remove}
    POST /api/playlists                {name}
    DELETE /api/playlists/<pid>
    POST /api/playlists/<pid>/songs    {song_id}
    POST /api/playlists/<pid>/songs/batch     {song_ids: [...]}
    POST /api/playlists/<pid>/songs/remove    {song_ids: [...]}
    DELETE /api/playlists/<pid>/songs/<sid>
"""

import base64
import hashlib
import hmac
import json
import mimetypes
import os
import queue
import re
import secrets
import socket
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
SETTING_FILE = os.path.join(BASE_DIR, "setting.json")
USER_FILE = os.path.join(BASE_DIR, "user.json")
LIBRARY_FILE = os.path.join(BASE_DIR, "library.json")

AUDIO_EXTS = {".mp3", ".flac", ".m4a", ".aac", ".ogg", ".opus",
              ".wav", ".wma", ".ape", ".alac", ".aiff", ".aif", ".m4b"}
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}

DEFAULT_SETTING = {
    "server_name": "音乐服务器",
    "host": "0.0.0.0",
    "port": 8080,
    "music_dir": "music",
    "lrc_dir": "lrc",
    "images_dir": "images",
    "token_hours": 720,
    "scan_cache_seconds": 5,
    "chunk_size": 262144,
}

DEFAULT_USER = "admin"
DEFAULT_PASSWORD = "admin123"

_lock = threading.Lock()


# --------------------------------------------------------------------------
# 配置 / 账号 / 数据库文件
# --------------------------------------------------------------------------

def _read_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def _write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


# --------------------------------------------------------------------------
# 歌词文本解码
# --------------------------------------------------------------------------
#
# 歌词文件来自各种播放器 / 网站，编码很杂：UTF-8（有无 BOM）、UTF-16、
# GBK/GB18030、Big5、Shift-JIS，还有西班牙语、法语这类老文件用的
# Windows-1252 / ISO-8859-1。
#
# 旧写法按 utf-8-sig -> utf-8 -> gbk -> utf-16 顺序"第一个不报错就用"。
# 问题出在 GBK：它几乎能把任意字节对解释成合法汉字，所以 1252 存的
# 歌词（"corazon" 带重音）在 utf-8 失败后会被 GBK 整篇吃掉，原地变成
# 一片随机汉字，永远走不到后面的分支——这就是西语歌词乱码的根因。
#
# 现在先判编码族再解码：
#   1. BOM 直接定；
#   2. 严格 UTF-8（自校验强，成功基本不会错）；
#   3. 零星坏字节的 UTF-8 用宽松解码，比整篇换编码更接近原文；
#   4. 零字节占比高 -> 无 BOM 的 UTF-16；
#   5. 看连续高位字节：双字节汉字 / 假名 / 谚文是成串的（run >= 3），
#      西语重音字母是单蹦的（run = 1）。据此分单字节池和双字节池；
#   6. 池内按"文字系统特征 + 控制字符惩罚"打分选最干净的那个。

_CJK_CODECS = ("gb18030", "big5", "shift_jis", "euc_kr")
_SINGLE_CODECS = ("cp1252", "cp1251", "latin-1")


def _text_penalty(text):
    """越小越干净。控制字符、替换符、私用区都是解错编码的信号。"""
    if not text:
        return 1.0
    bad = 0
    for ch in text:
        code = ord(ch)
        if code in (9, 10, 13):
            continue
        if code < 0x20 or 0x7F <= code <= 0x9F:
            bad += 1
        elif 0xD800 <= code <= 0xDFFF or 0xE000 <= code <= 0xF8FF:
            bad += 1
        elif code == 0xFFFD:
            bad += 1
    return bad / len(text)


def _cjk_ratio(text):
    hits = 0
    for ch in text:
        if 0x3400 <= ord(ch) <= 0x9FFF:
            hits += 1
    return hits / max(1, len(text))


def _longest_high_run(sample):
    """连续 >=0x80 字节的最长长度。"""
    run = best = 0
    for byte in sample:
        if byte >= 0x80:
            run += 1
            if run > best:
                best = run
        else:
            run = 0
    return best


def _pick_double_byte(raw):
    """双字节汉字系。假名、谚文是"解对了"的强证据，gb18030 会认出来。"""
    best = None
    best_score = None
    for codec in _CJK_CODECS:
        try:
            text = raw.decode(codec)
        except (UnicodeDecodeError, LookupError):
            continue
        kana = hangul = 0
        for ch in text:
            code = ord(ch)
            if 0x3040 <= code <= 0x30FF:
                kana += 1
            elif 0xAC00 <= code <= 0xD7A3:
                hangul += 1
        total = max(1, len(text))
        # 假名 / 谚文要占到一定比例才算"这本就是日文 / 韩文"。
        # 只出现零星几个就加分的话，GBK 中文会被 euc_kr 抢先解成谚文。
        score = 0.0
        if kana / total > 0.25:
            score += 3.0
        if hangul / total > 0.25:
            score += 3.0
        score -= _text_penalty(text) * 12
        if best_score is None or score > best_score:
            best, best_score = text, score
    return best


def _pick_single_byte(raw, high_ratio):
    """单字节系。

    cp1252 和 cp1251 在 0xC0-0xFF 都是字母，逐字符比对分不出拉丁语和
    西里尔语——但两者的**高位字节密度**差一个数量级：
    西语 / 法语的重音字母每个词才一个（10% 上下），俄语几乎整篇都是
    高位字节（60% 以上）。所以按密度决定先试哪一个。
    """
    order = _SINGLE_CODECS
    if high_ratio > 0.4:
        order = ("cp1251", "cp1252", "latin-1")
    for codec in order:
        try:
            return raw.decode(codec)
        except (UnicodeDecodeError, LookupError):
            continue
    return None


def decode_lyric_bytes(raw):
    if not raw:
        return ""
    if raw.startswith(b"\xef\xbb\xbf"):
        return raw[3:].decode("utf-8", "replace")
    if raw.startswith(b"\xff\xfe\x00\x00") or raw.startswith(b"\x00\x00\xfe\xff"):
        return raw.decode("utf-32", "replace")
    if raw.startswith(b"\xff\xfe"):
        return raw[2:].decode("utf-16-le", "replace")
    if raw.startswith(b"\xfe\xff"):
        return raw[2:].decode("utf-16-be", "replace")

    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        pass

    # 整篇只有一两个坏字节：宽松 UTF-8 比换编码更接近原文。
    loose = raw.decode("utf-8", "replace")
    if loose.count("\ufffd") <= 2 and len(loose) > 24:
        return loose

    sample = raw[:8192]
    if sample and sample.count(0) > len(sample) * 0.2:
        for codec in ("utf-16-le", "utf-16-be"):
            try:
                text = raw.decode(codec)
            except UnicodeDecodeError:
                continue
            if _text_penalty(text) <= 0.02:
                return text

    high = sum(1 for byte in sample if byte >= 0x80)
    high_ratio = high / max(1, len(sample))
    dense = _longest_high_run(sample) >= 3 and high_ratio > 0.12

    if dense:
        text = _pick_double_byte(raw)
        if text is not None:
            return text

    single = _pick_single_byte(raw, high_ratio)
    if single is not None and _cjk_ratio(single) < 0.05:
        return single

    double = _pick_double_byte(raw)
    if double is not None:
        return double
    if single is not None:
        return single
    return raw.decode("utf-8", "replace")


def load_setting():
    data = _read_json(SETTING_FILE, {})
    if not isinstance(data, dict):
        data = {}
    changed = False
    for key, value in DEFAULT_SETTING.items():
        if key not in data:
            data[key] = value
            changed = True
    if not data.get("secret"):
        data["secret"] = secrets.token_hex(32)
        changed = True
    if changed or not os.path.exists(SETTING_FILE):
        _write_json(SETTING_FILE, data)
    return data


def hash_password(password, salt=None, iterations=200000):
    if salt is None:
        salt = secrets.token_hex(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"),
                             salt.encode("utf-8"), iterations)
    return {"salt": salt, "hash": dk.hex(), "iterations": iterations}


def verify_password(password, record):
    if not isinstance(record, dict):
        return False
    try:
        calc = hashlib.pbkdf2_hmac(
            "sha256", password.encode("utf-8"),
            str(record.get("salt", "")).encode("utf-8"),
            int(record.get("iterations", 200000)))
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(calc.hex(), str(record.get("hash", "")))


def valid_username(name):
    """令牌用 | 分隔字段，用户名里不能出现会破坏解析的字符。"""
    if not name or len(name) > 32:
        return False
    for ch in name:
        if ch in "|/\\:" or ch.isspace():
            return False
    return True


def load_users():
    data = _read_json(USER_FILE, None)
    if not isinstance(data, dict) or "users" not in data:
        data = {"users": {}}
    if not data["users"]:
        data["users"][DEFAULT_USER] = hash_password(DEFAULT_PASSWORD)
        data["users"][DEFAULT_USER]["created"] = int(time.time())
        _write_json(USER_FILE, data)
        print("=" * 62)
        print(" 已生成默认账号： %s / %s" % (DEFAULT_USER, DEFAULT_PASSWORD))
        print(" 请尽快修改：python main.py user passwd %s <新密码>" % DEFAULT_USER)
        print("=" * 62)
    return data


_user_cache = {"mtime": -1.0, "data": None}
_user_cache_lock = threading.Lock()


def users_snapshot():
    """按需重读 user.json。

    setting.py / 命令行改完账号后立即生效，不用重启服务端。
    文件没变时直接返回缓存，不反复读盘。
    """
    try:
        mtime = os.path.getmtime(USER_FILE)
    except OSError:
        mtime = -1.0
    with _user_cache_lock:
        if mtime != _user_cache["mtime"] or _user_cache["data"] is None:
            _user_cache["data"] = load_users()
            _user_cache["mtime"] = mtime
        return _user_cache["data"]


def load_library():
    data = _read_json(LIBRARY_FILE, None)
    if not isinstance(data, dict):
        data = {"users": {}}
    if "users" not in data or not isinstance(data["users"], dict):
        data = {"users": {}}
    return data


def save_library(data):
    _write_json(LIBRARY_FILE, data)


def user_library(data, username):
    bucket = data["users"].get(username)
    if not isinstance(bucket, dict):
        bucket = {}
    bucket.setdefault("favorites", [])
    bucket.setdefault("playlists", [])
    data["users"][username] = bucket
    return bucket


# --------------------------------------------------------------------------
# 令牌
# --------------------------------------------------------------------------

def make_token(username, setting):
    exp = int(time.time()) + int(setting.get("token_hours", 720)) * 3600
    payload = "%s|%d" % (username, exp)
    sig = hmac.new(str(setting["secret"]).encode("utf-8"),
                   payload.encode("utf-8"), hashlib.sha256).hexdigest()[:40]
    raw = "%s|%s" % (payload, sig)
    return base64.urlsafe_b64encode(raw.encode("utf-8")).decode("ascii").rstrip("=")


def parse_token(token, setting):
    """返回用户名，失败返回 None。"""
    if not token:
        return None
    try:
        pad = "=" * (-len(token) % 4)
        raw = base64.urlsafe_b64decode(token + pad).decode("utf-8")
        username, exp, sig = raw.rsplit("|", 2)
        if int(exp) < int(time.time()):
            return None
        payload = "%s|%s" % (username, exp)
        expect = hmac.new(str(setting["secret"]).encode("utf-8"),
                          payload.encode("utf-8"), hashlib.sha256).hexdigest()[:40]
        if not hmac.compare_digest(sig, expect):
            return None
        return username
    except Exception:
        return None


# --------------------------------------------------------------------------
# 音频元数据（纯标准库，尽力而为）
# --------------------------------------------------------------------------

def _syncsafe(buf):
    return ((buf[0] & 0x7F) << 21) | ((buf[1] & 0x7F) << 14) | \
           ((buf[2] & 0x7F) << 7) | (buf[3] & 0x7F)


def _decode_text(enc, raw):
    raw = raw.rstrip(b"\x00")
    try:
        if enc == 0:
            return raw.decode("latin-1", "replace").strip("\x00 ").strip()
        if enc == 1:
            if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
                return raw.decode("utf-16", "replace").strip("\x00 ").strip()
            return raw.decode("utf-16-le", "replace").strip("\x00 ").strip()
        if enc == 2:
            return raw.decode("utf-16-be", "replace").strip("\x00 ").strip()
        return raw.decode("utf-8", "replace").strip("\x00 ").strip()
    except Exception:
        return ""


def read_id3v2(path):
    tags = {}
    try:
        with open(path, "rb") as f:
            head = f.read(10)
            if len(head) < 10 or head[:3] != b"ID3":
                return tags
            major = head[3]
            size = _syncsafe(head[6:10])
            body = f.read(size)
    except OSError:
        return tags

    wanted = {b"TIT2": "title", b"TPE1": "artist", b"TALB": "album",
              b"TLEN": "length", b"TRCK": "track", b"TYER": "year",
              b"TDRC": "year"}
    pos = 0
    idlen = 4 if major >= 4 else 4
    framelen = 4
    while pos + 10 <= len(body):
        fid = body[pos:pos + idlen]
        if not re.match(rb"^[A-Z0-9]{4}$", fid):
            break
        raw_size = body[pos + idlen:pos + idlen + framelen]
        if major >= 4:
            fsize = _syncsafe(raw_size)
            pos += 10
        else:
            fsize = int.from_bytes(raw_size, "big")
            pos += 10
        if fsize <= 0 or pos + fsize > len(body):
            break
        data = body[pos:pos + fsize]
        pos += fsize
        key = wanted.get(fid)
        if key and data:
            value = _decode_text(data[0], data[1:])
            if value:
                tags.setdefault(key, value)
    return tags


def read_id3v1(path):
    tags = {}
    try:
        size = os.path.getsize(path)
        if size < 128:
            return tags
        with open(path, "rb") as f:
            f.seek(-128, os.SEEK_END)
            block = f.read(128)
    except OSError:
        return tags
    if not block.startswith(b"TAG"):
        return tags
    try:
        title = block[3:33].decode("latin-1", "replace").strip("\x00 ").strip()
        artist = block[33:63].decode("latin-1", "replace").strip("\x00 ").strip()
        album = block[63:93].decode("latin-1", "replace").strip("\x00 ").strip()
    except Exception:
        return tags
    if title:
        tags["title"] = title
    if artist:
        tags["artist"] = artist
    if album:
        tags["album"] = album
    return tags


def read_flac(path):
    tags = {}
    try:
        with open(path, "rb") as f:
            if f.read(4) != b"fLaC":
                return tags
            for _ in range(32):
                header = f.read(4)
                if len(header) < 4:
                    break
                last = header[0] & 0x80
                btype = header[0] & 0x7F
                length = int.from_bytes(header[1:4], "big")
                if btype == 0 and length >= 18:
                    info = f.read(length)
                    sr = (info[10] << 12) | (info[11] << 4) | (info[12] >> 4)
                    total = ((info[13] & 0x0F) << 32) | int.from_bytes(info[14:18], "big")
                    if sr:
                        tags["duration"] = round(total / float(sr), 2)
                elif btype == 4:
                    block = f.read(length)
                    vendor_len = int.from_bytes(block[0:4], "little")
                    pos = 4 + vendor_len
                    count = int.from_bytes(block[pos:pos + 4], "little")
                    pos += 4
                    for _i in range(count):
                        if pos + 4 > len(block):
                            break
                        clen = int.from_bytes(block[pos:pos + 4], "little")
                        pos += 4
                        entry = block[pos:pos + clen].decode("utf-8", "replace")
                        pos += clen
                        if "=" not in entry:
                            continue
                        k, v = entry.split("=", 1)
                        k = k.upper()
                        if k == "TITLE":
                            tags.setdefault("title", v)
                        elif k == "ARTIST":
                            tags.setdefault("artist", v)
                        elif k == "ALBUM":
                            tags.setdefault("album", v)
                    break
                else:
                    f.seek(length, os.SEEK_CUR)
                if last:
                    break
    except OSError:
        pass
    return tags


def guess_from_filename(name):
    stem = os.path.splitext(name)[0]
    stem = re.sub(r"^\s*\d{1,3}[\s._-]+", "", stem)
    for sep in (" - ", " – ", "-", "—"):
        if sep in stem:
            left, right = stem.split(sep, 1)
            left, right = left.strip(), right.strip()
            if left and right:
                if re.search(r"[\u4e00-\u9fff]", left) or len(left) <= len(right):
                    return {"artist": left, "title": right}
                return {"artist": left, "title": right}
    return {"title": stem.strip() or name}


def read_tags(path):
    ext = os.path.splitext(path)[1].lower()
    tags = {}
    if ext == ".flac":
        tags = read_flac(path)
    elif ext in (".mp3", ".wma", ".ape"):
        tags = read_id3v2(path)
        if not tags.get("title"):
            tags.update({k: v for k, v in read_id3v1(path).items()
                         if k not in tags})
    if not tags.get("title") or not tags.get("artist"):
        fallback = guess_from_filename(os.path.basename(path))
        for k, v in fallback.items():
            tags.setdefault(k, v)
    if tags.get("length"):
        try:
            tags["duration"] = round(int(tags["length"]) / 1000.0, 2)
        except ValueError:
            pass
    return tags


# --------------------------------------------------------------------------
# 曲库扫描 + 歌词 / 封面匹配
# --------------------------------------------------------------------------

def file_version(path):
    """文件版本指纹：大小 + 修改时间。客户端用它判断缓存是否过期。"""
    if not path:
        return ""
    try:
        st = os.stat(path)
    except OSError:
        return ""
    raw = "%d:%d" % (st.st_size, int(st.st_mtime))
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()[:16]


class Library(object):
    def __init__(self, setting):
        self.setting = setting
        self.songs = []
        self.by_id = {}
        self._stamp = 0.0
        self._dir_stamp = None
        self._lock = threading.Lock()
        self._refreshing = False
        self._file_cache = {}

    def music_dir(self):
        return os.path.join(BASE_DIR, self.setting.get("music_dir", "music"))

    def lrc_dir(self):
        return os.path.join(BASE_DIR, self.setting.get("lrc_dir", "lrc"))

    def images_dir(self):
        return os.path.join(BASE_DIR, self.setting.get("images_dir", "images"))

    def _music_dir_stamp(self):
        try:
            return os.stat(self.music_dir()).st_mtime
        except OSError:
            return None

    def refresh(self, force=False):
        ttl = float(self.setting.get("scan_cache_seconds", 5))
        if not force and self.songs:
            # 音乐目录没动过就不用重扫，比按秒数过期省事也准
            stamp = self._music_dir_stamp()
            if stamp is not None and stamp == self._dir_stamp:
                return self.songs
            if time.time() - self._stamp < ttl:
                return self.songs

        with self._lock:
            # 已经有人在扫，直接把旧结果给它，不要排队等锁
            if self._refreshing:
                return self.songs
            if not force and self.songs and time.time() - self._stamp < ttl:
                return self.songs
            self._refreshing = True

        try:
            songs = self._scan()
        except Exception:
            with self._lock:
                self._refreshing = False
            return self.songs

        with self._lock:
            self.songs = songs
            self.by_id = {s["id"]: s for s in songs}
            self._stamp = time.time()
            self._dir_stamp = self._music_dir_stamp()
            self._refreshing = False
        return songs

    def _scan(self):
        """真正的扫描。**不能持锁运行**：读标签 + 匹配歌词封面很慢，
        持锁会把同时进来的播放请求一起堵死。"""
        songs = []
        root = self.music_dir()
        for dirpath, _dirnames, filenames in os.walk(root):
            for fn in filenames:
                if os.path.splitext(fn)[1].lower() not in AUDIO_EXTS:
                    continue
                full = os.path.join(dirpath, fn)
                try:
                    st = os.stat(full)
                except OSError:
                    continue
                rel = os.path.relpath(full, root)
                sid = hashlib.sha1(rel.replace("\\", "/").encode("utf-8")).hexdigest()[:16]
                tags = read_tags(full)
                lrc = self.find_lrc(full, tags.get("title"))
                cover = self.find_cover(full, tags.get("title"))
                songs.append({
                    "id": sid,
                    "name": tags.get("title") or os.path.splitext(fn)[0],
                    "artist": tags.get("artist") or "未知艺术家",
                    "album": tags.get("album") or "",
                    "ext": os.path.splitext(fn)[1].lower().lstrip("."),
                    "size": st.st_size,
                    "duration": tags.get("duration", 0),
                    "has_lrc": bool(lrc),
                    "has_cover": bool(cover),
                    "version": file_version(full),
                    "lrc_version": file_version(lrc),
                    "cover_version": file_version(cover),
                    "folder": os.path.dirname(rel).replace("\\", "/"),
                    "added": int(st.st_mtime),
                    "_path": full,
                    "_rel": rel.replace("\\", "/"),
                    "_lrc": lrc,
                    "_cover": cover,
                })
        songs.sort(key=lambda s: (s["folder"].lower(), s["name"].lower()))
        return songs

    def get(self, sid):
        # 播放 / 歌词 / 封面走的是热路径：命中就直接返回，
        # 绝不在这里触发扫描，否则每个分块请求都可能卡在扫盘上。
        song = self.by_id.get(sid)
        if song is not None:
            return song
        self.refresh()
        return self.by_id.get(sid)

    def _scan_files(self, root, exts):
        """把目录下的文件列成 (规整名, 完整路径)。按目录 mtime 缓存，
        否则每首歌都整目录遍历一次，曲库一大扫描就是平方级。"""
        if not os.path.isdir(root):
            return []
        try:
            stamp = os.stat(root).st_mtime
        except OSError:
            return []
        cached = self._file_cache.get(root)
        if cached is not None and cached[0] == stamp:
            return cached[1]
        files = []
        for dirpath, _dirnames, filenames in os.walk(root):
            for fn in filenames:
                base, ext = os.path.splitext(fn)
                if ext.lower() not in exts:
                    continue
                norm = re.sub(r"^\s*\d{1,3}[\s._-]+", "", base).strip().lower()
                files.append((norm, os.path.join(dirpath, fn)))
        self._file_cache[root] = (stamp, files)
        return files

    def find_lrc(self, audio_path, title=None):
        stem = os.path.splitext(os.path.basename(audio_path))[0]
        names = []
        for candidate in (stem, re.sub(r"^\s*\d{1,3}[\s._-]+", "", stem), title):
            if not candidate:
                continue
            norm = candidate.strip().lower()
            if norm and norm not in names:
                names.append(norm)

        same_dir = os.path.dirname(audio_path)
        for name in names:
            for suffix in (".lrc", ".LRC", ".Lrc"):
                path = os.path.join(same_dir, name + suffix)
                if os.path.isfile(path):
                    return path

        root = self.lrc_dir()
        if not os.path.isdir(root):
            return None

        files = self._scan_files(root, {".lrc"})

        for name in names:
            for base_norm, path in files:
                if base_norm == name:
                    return path

        # 兼容 "歌手 - 歌名.lrc" / "歌名 - 歌手.lrc" 这类命名
        for name in names:
            if len(name) < 2:
                continue
            for base_norm, path in files:
                if base_norm.endswith(" - " + name) or base_norm.startswith(name + " - "):
                    return path
        return None

    def find_cover(self, audio_path, title=None):
        """封面匹配：优先同名图片，其次 cover/folder/album，最后按歌名模糊匹配。"""
        stem = os.path.splitext(os.path.basename(audio_path))[0]
        names = []
        for candidate in (stem, re.sub(r"^\s*\d{1,3}[\s._-]+", "", stem), title):
            if not candidate:
                continue
            norm = candidate.strip().lower()
            if norm and norm not in names:
                names.append(norm)

        def pick(dirpath, bases):
            if not os.path.isdir(dirpath):
                return None
            try:
                entries = os.listdir(dirpath)
            except OSError:
                return None
            lookup = {}
            for fn in entries:
                base, ext = os.path.splitext(fn)
                if ext.lower() in IMAGE_EXTS:
                    lookup.setdefault(base.strip().lower(), os.path.join(dirpath, fn))
            for base in bases:
                if base in lookup:
                    return lookup[base]
            return None

        # 1) 音频同目录
        hit = pick(os.path.dirname(audio_path), names + ["cover", "folder", "album"])
        if hit:
            return hit

        root = self.images_dir()
        if not os.path.isdir(root):
            return None

        # 2) images 目录，按音频所在子目录对应
        rel_folder = os.path.relpath(os.path.dirname(audio_path), self.music_dir())
        if rel_folder not in (".", ""):
            hit = pick(os.path.join(root, rel_folder),
                       names + ["cover", "folder", "album"])
            if hit:
                return hit

        files = self._scan_files(root, IMAGE_EXTS)

        # 3) 同名图片
        for name in names:
            for base_norm, path in files:
                if base_norm == name:
                    return path

        # 4) 通用封面
        for generic in ("cover", "folder", "album", "封面"):
            for base_norm, path in files:
                if base_norm == generic:
                    return path

        # 5) "歌手 - 歌名.jpg"
        for name in names:
            if len(name) < 2:
                continue
            for base_norm, path in files:
                if base_norm.endswith(" - " + name) or base_norm.startswith(name + " - "):
                    return path
        return None


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

# 客户端（安卓播放器）在切歌 / 拖动进度 / 退到后台时一定会主动掐断旧连接，
# 这时服务端线程会拿到 WinError 10054（ConnectionResetError）。属于正常现象，
# 不该当成故障刷一屏回溯。
DISCONNECT_ERRORS = (ConnectionResetError, ConnectionAbortedError,
                     BrokenPipeError, TimeoutError, socket.timeout)

# 音频流里读线程的结束标记（正常读完 / 出异常都用它收尾）
_STREAM_DONE = object()


class Handler(BaseHTTPRequestHandler):
    server_version = "MusicServer/1.0"
    protocol_version = "HTTP/1.1"
    disable_nagle_algorithm = True

    # 由 ThreadingHTTPServer 注入
    setting = {}
    users = {}
    library = None
    lib_data = None

    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s\n" % (time.strftime("%H:%M:%S"), fmt % args))

    # 客户端断开时，http.server 默认会把回溯直接打到终端。
    # 这里把「读下一个请求」和「收尾 flush」两步的断开异常吃掉。
    def handle_one_request(self):
        try:
            BaseHTTPRequestHandler.handle_one_request(self)
        except DISCONNECT_ERRORS:
            self.close_connection = True

    def finish(self):
        try:
            BaseHTTPRequestHandler.finish(self)
        except (OSError, ValueError):
            pass

    # ---------------- 基础响应 ----------------

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")

    def send_json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self._cors()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            self.close_connection = True

    def send_text(self, text, status=200, ctype="text/plain; charset=utf-8"):
        body = text.encode("utf-8")
        self.send_response(status)
        self._cors()
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            self.close_connection = True

    def send_error_json(self, message, status=400):
        self.send_json({"ok": False, "error": message}, status)

    # ---------------- 请求解析 ----------------

    def parsed(self):
        split = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(split.query)
        return split.path, {k: v[0] for k, v in query.items()}

    def json_body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return {}
        if length <= 0 or length > 4 * 1024 * 1024:
            return {}
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
            return data if isinstance(data, dict) else {}
        except (ValueError, UnicodeDecodeError):
            return {}

    def current_user(self, query=None):
        token = query.get("token") if query else None
        if not token:
            auth = self.headers.get("Authorization") or ""
            if auth.lower().startswith("bearer "):
                token = auth[7:].strip()
        if not token:
            return None
        username = parse_token(token, self.setting)
        if username in users_snapshot().get("users", {}):
            return username
        return None

    def require_user(self, query=None):
        username = self.current_user(query)
        if not username:
            self.send_error_json("未登录或登录已失效", 401)
        return username

    # ---------------- 路由 ----------------

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_HEAD(self):
        path, _query = self.parsed()
        self._dispatch(path, head_only=True)

    def do_GET(self):
        path, _query = self.parsed()
        self._dispatch(path, head_only=False)

    def do_POST(self):
        path, _query = self.parsed()
        self._dispatch(path, method="POST")

    def do_DELETE(self):
        path, _query = self.parsed()
        self._dispatch(path, method="DELETE")

    def _dispatch(self, path, method="GET", head_only=False):
        try:
            _p, query = self.parsed()
            if path == "/" or path == "/api":
                self.send_json({
                    "ok": True,
                    "server": self.setting.get("server_name", "音乐服务器"),
                    "version": self.server_version,
                    "songs": len(self.library.refresh()),
                    "auth_required": True,
                })
                return

            if path == "/api/ping":
                self.send_json({
                    "ok": True,
                    "server": self.setting.get("server_name", "音乐服务器"),
                    "version": self.server_version,
                    "songs": len(self.library.refresh()),
                    "time": int(time.time()),
                })
                return

            if path == "/api/login" and method == "POST":
                self.handle_login()
                return

            if path == "/api/config":
                self.handle_config(query)
                return

            if path.startswith("/api/stream/"):
                self.handle_stream(path[len("/api/stream/"):], query, head_only)
                return

            if path.startswith("/api/lrc/"):
                self.handle_lrc(path[len("/api/lrc/"):], query)
                return

            if path.startswith("/api/cover/"):
                self.handle_cover(path[len("/api/cover/"):], query, head_only)
                return

            if path == "/api/songs":
                username = self.require_user(query)
                if not username:
                    return
                self.refresh_library_if_needed(query)
                items = [{k: v for k, v in s.items() if not k.startswith("_")}
                         for s in self.library.refresh()]
                self.send_json({"ok": True, "songs": items})
                return

            if path == "/api/library":
                username = self.require_user(query)
                if not username:
                    return
                self.send_json(self.library_payload(username))
                return

            if path == "/api/favorites/toggle" and method == "POST":
                self.handle_favorite_toggle()
                return

            if path == "/api/favorites/batch" and method == "POST":
                self.handle_favorites_batch()
                return

            if path == "/api/favorites/order" and method == "POST":
                self.handle_favorites_order()
                return

            if path == "/api/playlists" and method == "POST":
                self.handle_playlist_create()
                return

            m = re.match(r"^/api/playlists/([^/]+)/order$", path)
            if m and method == "POST":
                self.handle_playlist_order(m.group(1))
                return

            m = re.match(r"^/api/playlists/([^/]+)/songs/batch$", path)
            if m and method == "POST":
                self.handle_playlist_add_songs(m.group(1))
                return

            m = re.match(r"^/api/playlists/([^/]+)/songs/remove$", path)
            if m and method == "POST":
                self.handle_playlist_remove_songs(m.group(1))
                return

            m = re.match(r"^/api/playlists/([^/]+)/songs/([^/]+)$", path)
            if m and method == "DELETE":
                self.handle_playlist_remove_song(m.group(1), m.group(2))
                return

            m = re.match(r"^/api/playlists/([^/]+)/songs$", path)
            if m and method == "POST":
                self.handle_playlist_add_song(m.group(1))
                return

            m = re.match(r"^/api/playlists/([^/]+)$", path)
            if m and method == "DELETE":
                self.handle_playlist_delete(m.group(1))
                return

            self.send_error_json("接口不存在: %s" % path, 404)
        except OSError as exc:
            # 客户端中途掐断连接（WinError 10053/10054）走这里，属正常
            if not isinstance(exc, DISCONNECT_ERRORS):
                sys.stderr.write("[%s] 连接异常: %s: %s\n" % (
                    time.strftime("%H:%M:%S"), type(exc).__name__, exc))
            self.close_connection = True
        except Exception as exc:  # 兜底，避免线程炸掉吞掉连接
            try:
                self.send_error_json("服务器错误: %s" % exc, 500)
            except Exception:
                pass

    # ---------------- 具体接口 ----------------

    def refresh_library_if_needed(self, query):
        if query.get("refresh") in ("1", "true"):
            self.library.refresh(force=True)

    def handle_login(self):
        body = self.json_body()
        username = str(body.get("username", "")).strip()
        password = str(body.get("password", ""))
        if not username or not password:
            self.send_error_json("用户名和密码不能为空", 400)
            return
        record = users_snapshot().get("users", {}).get(username)
        if not record or not verify_password(password, record):
            time.sleep(0.35)  # 轻微延时，压制暴力尝试
            self.send_error_json("用户名或密码错误", 401)
            return
        token = make_token(username, self.setting)
        self.send_json({
            "ok": True,
            "token": token,
            "username": username,
            "server": self.setting.get("server_name", "音乐服务器"),
            "songs": len(self.library.refresh()),
            "expires_in": int(self.setting.get("token_hours", 720)) * 3600,
        })

    def _chunk_size(self):
        """分块大小，来源是 setting.json 的 chunk_size。

        每次调用都重读文件 —— 改完 setting.json 立刻生效，不用重启；
        其余配置仍然只在启动时读一次。
        """
        chunk = _read_json(SETTING_FILE, {}).get(
            "chunk_size", self.setting.get("chunk_size", 262144))
        try:
            chunk = int(chunk)
        except (TypeError, ValueError):
            chunk = 262144
        # 太小会把一首歌拆成上千次请求，太大又失去分块的意义
        return max(16 * 1024, min(chunk, 8 * 1024 * 1024))

    def handle_config(self, query):
        """客户端配置：分块下载的块大小等。"""
        username = self.require_user(query)
        if not username:
            return
        self.send_json({
            "ok": True,
            "server": self.setting.get("server_name", "音乐服务器"),
            "chunk_size": self._chunk_size(),
        })

    def handle_stream(self, sid, query, head_only=False):
        username = self.require_user(query)
        if not username:
            return
        song = self.library.get(sid)
        if not song:
            self.send_error_json("歌曲不存在", 404)
            return
        path = song["_path"]
        try:
            size = os.path.getsize(path)
        except OSError:
            self.send_error_json("文件不可读", 404)
            return

        ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
        if song["ext"] in ("flac",):
            ctype = "audio/flac"
        elif song["ext"] in ("m4a", "m4b", "alac"):
            ctype = "audio/mp4"
        elif song["ext"] == "mp3":
            ctype = "audio/mpeg"
        elif song["ext"] == "opus":
            ctype = "audio/ogg"

        start, end = 0, size - 1
        status = 200
        range_header = self.headers.get("Range")
        if range_header:
            m = re.match(r"bytes=(\d*)-(\d*)", range_header.strip())
            if m:
                g1, g2 = m.group(1), m.group(2)
                if g1 == "" and g2 != "":
                    length = int(g2)
                    start = max(0, size - length)
                    end = size - 1
                else:
                    start = int(g1 or 0)
                    end = int(g2) if g2 else size - 1
                start = max(0, min(start, size - 1))
                end = max(start, min(end, size - 1))
                status = 206

        length = end - start + 1
        self.send_response(status)
        self._cors()
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(length))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Disposition", 'inline; filename="audio"')
        # 音频流走完就关连接：客户端拖动进度会重开新连接，
        # 长连接留着只会让线程挂在 write 上直到被 RST。
        self.send_header("Connection", "close")
        if status == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.close_connection = True
        self.end_headers()

        if head_only:
            return

        chunk_size = self._chunk_size()
        try:
            self._stream_audio(path, start, length, chunk_size)
        except DISCONNECT_ERRORS:
            pass

    def _stream_audio(self, path, start, length, chunk_size):
        """边读边发：发当前块的同时，读线程已经把下一块备好了。

        单线程里 read 和 write 是串行的，发一块要等「读一块 + 写一块」；
        客户端一慢，磁盘就闲着，反过来也是。这里开一个读线程，用只放一块
        的队列做双缓冲：
            writer: 写块 0 ── 写块 1 ── 写块 2
            reader:    读块 1 ─┐   读块 2 ─┐
                       队列满就等，最多领先一块
        稳态下每块的耗时只看网络，内存固定占一到两块，不会把整首歌读进来。
        """
        stop = threading.Event()
        pending = queue.Queue(maxsize=1)

        # 客户端按块请求时 length 正好等于一块，一次读就完事，不用开线程
        if length <= chunk_size:
            try:
                with open(path, "rb") as f:
                    f.seek(start)
                    data = f.read(length)
                if data:
                    self.wfile.write(data)
            except OSError:
                pass
            return

        def reader():
            try:
                remaining = length
                with open(path, "rb") as f:
                    f.seek(start)
                    while remaining > 0 and not stop.is_set():
                        data = f.read(min(chunk_size, remaining))
                        if not data:
                            break
                        remaining -= len(data)
                        # 队列满说明 writer 还没把上一块发完，等着
                        while not stop.is_set():
                            try:
                                pending.put(data, timeout=0.2)
                                break
                            except queue.Full:
                                continue
            except OSError:
                # 头已经发出去了，没法再改状态码，让客户端按短响应处理
                pass
            finally:
                while not stop.is_set():
                    try:
                        pending.put(_STREAM_DONE, timeout=0.2)
                        break
                    except queue.Full:
                        continue

        worker = threading.Thread(target=reader, name="audio-reader", daemon=True)
        worker.start()
        try:
            while True:
                data = pending.get()
                if data is _STREAM_DONE:
                    break
                self.wfile.write(data)
        finally:
            # 客户端断开时 writer 先抛异常；读线程看到 stop 才会从满队列里退出来
            stop.set()

    def handle_lrc(self, sid, query):
        username = self.require_user(query)
        if not username:
            return
        song = self.library.get(sid)
        if not song:
            self.send_error_json("歌曲不存在", 404)
            return
        lrc = song.get("_lrc")
        if not lrc or not os.path.isfile(lrc):
            self.send_error_json("没有歌词", 404)
            return
        try:
            with open(lrc, "rb") as f:
                raw = f.read()
        except OSError:
            self.send_error_json("歌词读取失败", 500)
            return
        text = decode_lyric_bytes(raw)
        if not text.strip():
            self.send_error_json("歌词读取失败", 500)
            return
        self.send_text(text)

    def handle_cover(self, sid, query, head_only=False):
        username = self.require_user(query)
        if not username:
            return
        song = self.library.get(sid)
        if not song:
            self.send_error_json("歌曲不存在", 404)
            return
        path = song.get("_cover")
        if not path or not os.path.isfile(path):
            self.send_error_json("没有封面", 404)
            return
        try:
            with open(path, "rb") as f:
                body = f.read()
        except OSError:
            self.send_error_json("封面读取失败", 500)
            return
        ctype = mimetypes.guess_type(path)[0] or "image/jpeg"
        self.send_response(200)
        self._cors()
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("ETag", '"%s"' % song.get("cover_version", ""))
        self.end_headers()
        if head_only:
            return
        try:
            self.wfile.write(body)
        except OSError:
            self.close_connection = True

    def library_payload(self, username):
        with _lock:
            data = load_library()
            bucket = user_library(data, username)
            return {
                "ok": True,
                "username": username,
                "favorites": list(bucket.get("favorites", [])),
                "playlists": list(bucket.get("playlists", [])),
            }

    def handle_favorite_toggle(self):
        username = self.require_user()
        if not username:
            return
        body = self.json_body()
        sid = str(body.get("song_id", "")).strip()
        if not sid:
            self.send_error_json("缺少 song_id", 400)
            return
        with _lock:
            data = load_library()
            bucket = user_library(data, username)
            favs = bucket["favorites"]
            if sid in favs:
                favs.remove(sid)
                action = "removed"
            else:
                # 后收藏的排在最前面
                favs.insert(0, sid)
                action = "added"
            save_library(data)
        self.send_json({"ok": True, "action": action, "favorites": favs})

    def handle_favorites_batch(self):
        """批量收藏 / 取消收藏。

        多选时一次请求搞定，省得客户端为几十首歌发几十个请求。
        **已经收藏的不再重复插入，本来没收藏的也不会被"取消"**，
        多余的、重复的 id 直接跳过，返回值里能看出实际改了几首。
        """
        username = self.require_user()
        if not username:
            return
        body = self.json_body()
        raw = body.get("song_ids")
        if not isinstance(raw, list):
            self.send_error_json("缺少 song_ids", 400)
            return
        action = str(body.get("action", "add")).strip().lower()
        if action not in ("add", "remove"):
            self.send_error_json("action 只能是 add 或 remove", 400)
            return
        ids = []
        for item in raw:
            sid = str(item).strip()
            if sid and sid not in ids:
                ids.append(sid)
        changed = 0
        with _lock:
            data = load_library()
            bucket = user_library(data, username)
            favs = bucket["favorites"]
            if action == "add":
                # 一次多选整体排在收藏最前，保持选中的先后顺序
                fresh = [sid for sid in ids if sid not in favs]
                if fresh:
                    bucket["favorites"] = fresh + list(favs)
                    changed = len(fresh)
            else:
                keep = [sid for sid in favs if sid not in ids]
                changed = len(favs) - len(keep)
                bucket["favorites"] = keep
            if changed:
                save_library(data)
            favs = list(bucket["favorites"])
        self.send_json({
            "ok": True,
            "changed": changed,
            "skipped": len(ids) - changed,
            "favorites": favs,
        })

    def handle_favorites_order(self):
        """整体保存收藏顺序。只认当前已有的歌，漏掉的补在末尾，不丢数据。"""
        username = self.require_user()
        if not username:
            return
        body = self.json_body()
        order = body.get("songs")
        if not isinstance(order, list):
            self.send_error_json("缺少 songs", 400)
            return
        wanted = [str(x) for x in order]
        with _lock:
            data = load_library()
            bucket = user_library(data, username)
            current = bucket["favorites"]
            cleaned = self._merge_order(current, wanted)
            bucket["favorites"] = cleaned
            save_library(data)
        self.send_json({"ok": True, "favorites": cleaned})

    @staticmethod
    def _merge_order(current, wanted):
        allowed = set(current)
        cleaned = []
        for sid in wanted:
            if sid in allowed and sid not in cleaned:
                cleaned.append(sid)
        for sid in current:
            if sid not in cleaned:
                cleaned.append(sid)
        return cleaned

    def handle_playlist_create(self):
        username = self.require_user()
        if not username:
            return
        body = self.json_body()
        name = str(body.get("name", "")).strip()
        if not name:
            self.send_error_json("歌单名不能为空", 400)
            return
        if len(name) > 60:
            self.send_error_json("歌单名太长", 400)
            return
        with _lock:
            data = load_library()
            bucket = user_library(data, username)
            pid = secrets.token_hex(6)
            bucket["playlists"].append({
                "id": pid,
                "name": name,
                "songs": [],
                "created": int(time.time()),
            })
            save_library(data)
            playlists = bucket["playlists"]
        self.send_json({"ok": True, "playlists": playlists, "playlist_id": pid})

    def handle_playlist_delete(self, pid):
        username = self.require_user()
        if not username:
            return
        with _lock:
            data = load_library()
            bucket = user_library(data, username)
            before = len(bucket["playlists"])
            bucket["playlists"] = [p for p in bucket["playlists"] if p.get("id") != pid]
            if len(bucket["playlists"]) == before:
                self.send_error_json("歌单不存在", 404)
                return
            save_library(data)
            playlists = bucket["playlists"]
        self.send_json({"ok": True, "playlists": playlists})

    def handle_playlist_add_song(self, pid):
        username = self.require_user()
        if not username:
            return
        body = self.json_body()
        sid = str(body.get("song_id", "")).strip()
        if not sid:
            self.send_error_json("缺少 song_id", 400)
            return
        with _lock:
            data = load_library()
            bucket = user_library(data, username)
            target = None
            for p in bucket["playlists"]:
                if p.get("id") == pid:
                    target = p
                    break
            if target is None:
                self.send_error_json("歌单不存在", 404)
                return
            songs = target.setdefault("songs", [])
            if sid not in songs:
                # 后加的排在最前面
                songs.insert(0, sid)
            save_library(data)
            playlists = bucket["playlists"]
        self.send_json({"ok": True, "playlists": playlists})

    def handle_playlist_add_songs(self, pid):
        """批量加入歌单。已在歌单里的自动跳过，新的整体排在歌单最前面。"""
        username = self.require_user()
        if not username:
            return
        ids = self._body_song_ids()
        if ids is None:
            return
        with _lock:
            data = load_library()
            bucket = user_library(data, username)
            target = None
            for p in bucket["playlists"]:
                if p.get("id") == pid:
                    target = p
                    break
            if target is None:
                self.send_error_json("歌单不存在", 404)
                return
            songs = target.setdefault("songs", [])
            fresh = [sid for sid in ids if sid not in songs]
            if fresh:
                target["songs"] = fresh + list(songs)
                save_library(data)
            playlists = bucket["playlists"]
        self.send_json({
            "ok": True,
            "changed": len(fresh),
            "skipped": len(ids) - len(fresh),
            "playlists": playlists,
        })

    def handle_playlist_remove_songs(self, pid):
        """批量从歌单移除。不在歌单里的直接跳过。"""
        username = self.require_user()
        if not username:
            return
        ids = self._body_song_ids()
        if ids is None:
            return
        with _lock:
            data = load_library()
            bucket = user_library(data, username)
            target = None
            for p in bucket["playlists"]:
                if p.get("id") == pid:
                    target = p
                    break
            if target is None:
                self.send_error_json("歌单不存在", 404)
                return
            songs = target.setdefault("songs", [])
            drop = set(ids)
            keep = [sid for sid in songs if sid not in drop]
            changed = len(songs) - len(keep)
            if changed:
                target["songs"] = keep
                save_library(data)
            playlists = bucket["playlists"]
        self.send_json({
            "ok": True,
            "changed": changed,
            "skipped": len(ids) - changed,
            "playlists": playlists,
        })

    def _body_song_ids(self):
        """取 body 里的 song_ids，去空、去重。返回 None 表示已经回过错误。"""
        body = self.json_body()
        raw = body.get("song_ids")
        if not isinstance(raw, list):
            self.send_error_json("缺少 song_ids", 400)
            return None
        ids = []
        for item in raw:
            sid = str(item).strip()
            if sid and sid not in ids:
                ids.append(sid)
        if not ids:
            self.send_error_json("song_ids 不能为空", 400)
            return None
        return ids

    def handle_playlist_order(self, pid):
        username = self.require_user()
        if not username:
            return
        body = self.json_body()
        order = body.get("songs")
        if not isinstance(order, list):
            self.send_error_json("缺少 songs", 400)
            return
        wanted = [str(x) for x in order]
        with _lock:
            data = load_library()
            bucket = user_library(data, username)
            target = None
            for p in bucket["playlists"]:
                if p.get("id") == pid:
                    target = p
                    break
            if target is None:
                self.send_error_json("歌单不存在", 404)
                return
            target["songs"] = self._merge_order(target.get("songs", []), wanted)
            save_library(data)
            playlists = bucket["playlists"]
        self.send_json({"ok": True, "playlists": playlists})

    def handle_playlist_remove_song(self, pid, sid):
        username = self.require_user()
        if not username:
            return
        with _lock:
            data = load_library()
            bucket = user_library(data, username)
            target = None
            for p in bucket["playlists"]:
                if p.get("id") == pid:
                    target = p
                    break
            if target is None:
                self.send_error_json("歌单不存在", 404)
                return
            songs = target.setdefault("songs", [])
            if sid in songs:
                songs.remove(sid)
            save_library(data)
            playlists = bucket["playlists"]
        self.send_json({"ok": True, "playlists": playlists})


# --------------------------------------------------------------------------
# 启动
# --------------------------------------------------------------------------

class MusicServer(ThreadingHTTPServer):
    """连接被客户端掐断时不打回溯，只记一句；其他异常仍照常报。"""
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64

    def handle_error(self, request, client_address):
        exc = sys.exc_info()[1]
        if isinstance(exc, DISCONNECT_ERRORS):
            return
        sys.stderr.write("[%s] 请求处理出错 %s: %s: %s\n" % (
            time.strftime("%H:%M:%S"), client_address,
            type(exc).__name__, exc))


def local_ips():
    ips = []
    try:
        hostname = socket.gethostname()
        for info in socket.getaddrinfo(hostname, None, socket.AF_INET):
            ip = info[4][0]
            if ip not in ips and not ip.startswith("127."):
                ips.append(ip)
    except OSError:
        pass
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        if ip not in ips and not ip.startswith("127."):
            ips.insert(0, ip)
        s.close()
    except OSError:
        pass
    return ips


def cmd_user(args):
    users = load_users()
    if not args or args[0] == "list":
        for name, record in users["users"].items():
            print("  %-20s %s" % (name, time.strftime(
                "%Y-%m-%d %H:%M", time.localtime(record.get("created", 0)))))
        return
    action = args[0]
    if action == "add":
        if len(args) < 3:
            print("用法: python main.py user add <用户名> <密码>")
            return
        name, pwd = args[1], args[2]
        if not valid_username(name):
            print("用户名不合法：不能为空，不能含 | / \\ : 或空白字符")
            return
        if name in users["users"]:
            print("用户已存在：%s" % name)
            return
        users["users"][name] = hash_password(pwd)
        users["users"][name]["created"] = int(time.time())
        _write_json(USER_FILE, users)
        print("已添加用户：%s" % name)
        return
    if action in ("rename", "mv"):
        if len(args) < 3:
            print("用法: python main.py user rename <旧用户名> <新用户名>")
            return
        old, new = args[1], args[2]
        if old not in users["users"]:
            print("用户不存在：%s" % old)
            return
        if not valid_username(new):
            print("用户名不合法：不能为空，不能含 | / \\ : 或空白字符")
            return
        if new in users["users"]:
            print("用户名已被占用：%s" % new)
            return
        record = users["users"].pop(old)
        users["users"][new] = record
        _write_json(USER_FILE, users)
        # 收藏 / 歌单跟着账号走
        lib = load_library()
        if old in lib["users"]:
            lib["users"][new] = lib["users"].pop(old)
            save_library(lib)
        print("已改名：%s -> %s" % (old, new))
        return
    if action == "del":
        if len(args) < 2:
            print("用法: python main.py user del <用户名>")
            return
        if args[1] not in users["users"]:
            print("用户不存在：%s" % args[1])
            return
        del users["users"][args[1]]
        _write_json(USER_FILE, users)
        print("已删除用户：%s" % args[1])
        return
    if action in ("passwd", "password", "reset"):
        if len(args) < 3:
            print("用法: python main.py user passwd <用户名> <新密码>")
            return
        name, pwd = args[1], args[2]
        if name not in users["users"]:
            print("用户不存在：%s" % name)
            return
        record = hash_password(pwd)
        record["created"] = users["users"][name].get("created", int(time.time()))
        users["users"][name] = record
        _write_json(USER_FILE, users)
        print("已更新密码：%s" % name)
        return
    print("未知命令。可用：list / add / del / passwd")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "user":
        cmd_user(sys.argv[2:])
        return

    setting = load_setting()
    users = users_snapshot()

    music_dir = os.path.join(BASE_DIR, setting.get("music_dir", "music"))
    lrc_dir = os.path.join(BASE_DIR, setting.get("lrc_dir", "lrc"))
    images_dir = os.path.join(BASE_DIR, setting.get("images_dir", "images"))
    os.makedirs(music_dir, exist_ok=True)
    os.makedirs(lrc_dir, exist_ok=True)
    os.makedirs(images_dir, exist_ok=True)

    library = Library(setting)
    count = len(library.refresh(force=True))

    Handler.setting = setting
    Handler.users = users
    Handler.library = library
    if not os.path.exists(LIBRARY_FILE):
        save_library({"users": {}})

    host = setting.get("host", "0.0.0.0")
    port = int(setting.get("port", 8080))

    httpd = MusicServer((host, port), Handler)

    print("")
    print("  音乐服务器已启动")
    print("  监听      : http://%s:%d" % (host, port))
    for ip in local_ips():
        print("  局域网地址: http://%s:%d" % (ip, port))
    print("  音乐目录  : %s" % music_dir)
    print("  歌词目录  : %s" % lrc_dir)
    print("  封面目录  : %s" % images_dir)
    print("  曲库数量  : %d" % count)
    print("  用户      : %s" % ", ".join(users.get("users", {}).keys()))
    print("  设置文件  : %s" % SETTING_FILE)
    print("  按 Ctrl+C 停止")
    print("")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止。")
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
