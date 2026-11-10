#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
音乐服务器 · 账号管理

运行：
    python setting.py                       交互式菜单
    python setting.py list
    python setting.py add <用户名> <密码>
    python setting.py del <用户名>
    python setting.py rename <旧用户名> <新用户名>
    python setting.py passwd <用户名> <新密码>

改完立即生效：服务端会按 user.json 的修改时间自动重读，不用重启。
"""

import sys
import time

import main as srv


# --------------------------------------------------------------------------
# 展示
# --------------------------------------------------------------------------

def show_accounts(users):
    entries = users.get("users", {})
    if not entries:
        print("  （还没有账号）")
        return
    print("  %-20s %s" % ("用户名", "创建时间"))
    print("  " + "-" * 44)
    for name, record in entries.items():
        created = record.get("created", 0) if isinstance(record, dict) else 0
        stamp = time.strftime("%Y-%m-%d %H:%M", time.localtime(created)) \
            if created else "-"
        print("  %-20s %s" % (name, stamp))
    print("  共 %d 个账号" % len(entries))


# --------------------------------------------------------------------------
# 操作
# --------------------------------------------------------------------------

def _save(users):
    srv._write_json(srv.USER_FILE, users)


def do_add(name, password):
    users = srv.load_users()
    if not srv.valid_username(name):
        print("  × 用户名不合法：不能为空、不能超过 32 字、不能含 | / \\ : 或空格")
        return False
    if not password:
        print("  × 密码不能为空")
        return False
    if name in users.get("users", {}):
        print("  × 用户已存在：%s" % name)
        return False
    users["users"][name] = srv.hash_password(password)
    users["users"][name]["created"] = int(time.time())
    _save(users)
    print("  √ 已添加账号：%s" % name)
    return True


def do_delete(name):
    users = srv.load_users()
    if name not in users.get("users", {}):
        print("  × 用户不存在：%s" % name)
        return False
    if len(users["users"]) <= 1:
        print("  × 这是最后一个账号，删掉就没人能登录了")
        return False
    del users["users"][name]
    _save(users)
    print("  √ 已删除账号：%s" % name)
    return True


def do_rename(old, new):
    users = srv.load_users()
    if old not in users.get("users", {}):
        print("  × 用户不存在：%s" % old)
        return False
    if not srv.valid_username(new):
        print("  × 用户名不合法：不能为空、不能超过 32 字、不能含 | / \\ : 或空格")
        return False
    if new in users["users"]:
        print("  × 用户名已被占用：%s" % new)
        return False
    users["users"][new] = users["users"].pop(old)
    _save(users)

    # 收藏和歌单跟着账号走
    library = srv.load_library()
    if old in library.get("users", {}):
        library["users"][new] = library["users"].pop(old)
        srv.save_library(library)
    print("  √ 已改名：%s → %s" % (old, new))
    return True


def do_passwd(name, password):
    users = srv.load_users()
    if name not in users.get("users", {}):
        print("  × 用户不存在：%s" % name)
        return False
    if not password:
        print("  × 密码不能为空")
        return False
    record = srv.hash_password(password)
    old = users["users"][name]
    record["created"] = old.get("created", int(time.time())) \
        if isinstance(old, dict) else int(time.time())
    users["users"][name] = record
    _save(users)
    print("  √ 已修改密码：%s" % name)
    return True


# --------------------------------------------------------------------------
# 交互菜单
# --------------------------------------------------------------------------

def interactive():
    # Windows 控制台用 GBK，遇到打不出的字符别直接崩
    try:
        sys.stdout.reconfigure(errors="replace")
    except (AttributeError, ValueError):
        pass

    while True:
        users = srv.load_users()
        print()
        print("=" * 54)
        print("  音乐服务器 · 账号管理")
        print("=" * 54)
        show_accounts(users)
        print()
        print("  1) 添加账号   2) 删除账号   3) 改名")
        print("  4) 改密码     5) 刷新       0) 退出")
        try:
            choice = input("  请选择: ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return

        if choice in ("0", "q", "Q"):
            return
        if choice == "5" or choice == "":
            continue
        if choice == "1":
            name = input("  新用户名: ").strip()
            password = input("  密码: ")
            do_add(name, password)
        elif choice == "2":
            name = input("  要删除的用户名: ").strip()
            answer = input("  确认删除 %s ？(y/N) " % name).strip().lower()
            if answer == "y":
                do_delete(name)
            else:
                print("  已取消")
        elif choice == "3":
            old = input("  原用户名: ").strip()
            new = input("  新用户名: ").strip()
            do_rename(old, new)
        elif choice == "4":
            name = input("  用户名: ").strip()
            password = input("  新密码: ")
            do_passwd(name, password)
        else:
            print("  × 没有这个选项")


# --------------------------------------------------------------------------
# 命令行
# --------------------------------------------------------------------------

def cli(args):
    action = args[0].lower()
    if action in ("list", "ls"):
        show_accounts(srv.load_users())
        return True
    if action == "add":
        if len(args) < 3:
            print("用法: python setting.py add <用户名> <密码>")
            return False
        return do_add(args[1], args[2])
    if action in ("del", "delete", "rm"):
        if len(args) < 2:
            print("用法: python setting.py del <用户名>")
            return False
        return do_delete(args[1])
    if action in ("rename", "mv"):
        if len(args) < 3:
            print("用法: python setting.py rename <旧用户名> <新用户名>")
            return False
        return do_rename(args[1], args[2])
    if action in ("passwd", "password", "reset"):
        if len(args) < 3:
            print("用法: python setting.py passwd <用户名> <新密码>")
            return False
        return do_passwd(args[1], args[2])
    print("未知命令。可用：list / add / del / rename / passwd")
    return False


def main():
    args = sys.argv[1:]
    if not args:
        interactive()
        return
    ok = cli(args)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
