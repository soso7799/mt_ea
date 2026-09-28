#!/usr/bin/env python3
"""
把 src/Experts/*.mq5 的 #include "BeeQuant/..." 展開成單一檔案，
輸出到 MQL5/Experts/BeeQuant12/。產生的 .mq5 不依賴任何 .mqh，
放在 MT5 的 MQL5\\Experts\\ 底下任何位置都能直接編譯。

修改 EA 或函式庫後執行：python tools/build_single.py
"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src", "Experts")
OUT = os.path.join(ROOT, "MQL5", "Experts", "BeeQuant12")
INC = re.compile(r'^\s*#include\s+"([^"]+)"\s*$')


def read(path):
    with open(path, encoding="utf-8-sig") as f:
        return f.read().replace("\r\n", "\n")


def expand(path, done):
    out = []
    for line in read(path).split("\n"):
        m = INC.match(line)
        if m:
            inc = os.path.normpath(os.path.join(os.path.dirname(path), m.group(1)))
            if inc in done:
                continue
            done.add(inc)
            name = os.path.basename(inc)
            out.append(f"//==================== 內嵌函式庫：{name} ====================")
            out.append(expand(inc, done))
            out.append(f"//==================== {name} 結束 ====================")
        else:
            out.append(line)
    return "\n".join(out)


def main():
    os.makedirs(OUT, exist_ok=True)
    for name in sorted(os.listdir(SRC)):
        if not name.endswith(".mq5"):
            continue
        text = expand(os.path.join(SRC, name), set())
        text = ("//  ※ 本檔由 tools/build_single.py 自動產生 (已內嵌 BeeQuant 函式庫)，\n"
                "//    可直接放在 MQL5\\Experts\\ 任何位置編譯；要修改請改 src/ 後重新產生。\n") + text
        with open(os.path.join(OUT, name), "wb") as f:
            f.write(b"\xef\xbb\xbf" + text.replace("\n", "\r\n").encode("utf-8"))
        print("產生", name)


if __name__ == "__main__":
    main()
