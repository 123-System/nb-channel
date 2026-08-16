# -*- coding: utf-8 -*-
"""
PythonAnywhere WSGI 入口。
在 PythonAnywhere Web 面板中把 WSGI 配置文件路径指向本文件。
"""
import sys
import os

# 把当前目录加入模块搜索路径
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
if BASE_DIR not in sys.path:
    sys.path.insert(0, BASE_DIR)

from app import app as application  # noqa: E402
