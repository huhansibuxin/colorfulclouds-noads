TARGET := iphone:clang:latest:16.0
ARCHS := arm64 arm64e
THEOS_PACKAGE_SCHEME := rootless

# v2.1.1 性能修复：整个 dylib 一直是被 -O0 编译的。要修干净必须同时动三个变量，
# 只写 OPTFLAG 是**没用的**（v2.1.0 实测：两版产物逐函数指令数完全相同，-O0 原封不动）。
#
# 链条（theos makefiles/common.mk）：
#   既不给 FINALPACKAGE 也不给 DEBUG
#     → `DEBUG := 1`                            # := 强赋值
#     → THEOS_SCHEMA 带上 DEBUG
#     → DEBUG schema 把 `DEBUG.CFLAGS = -DDEBUG -O0` 追加到 CFLAGS **末尾**
#       ← 这就是 OPTFLAG=-O2 被压掉的原因：-O0 在命令行上更靠后
#     → 同一个 schema 还让 _THEOS_SHOULD_STRIP_DEFAULT := false
#     → SHOULD_STRIP 又恰好决定优化级别的默认值：
#         SHOULD_STRIP=true  → OPTFLAG ?= -Os（+ 真 strip）
#         SHOULD_STRIP=false → TARGET_STRIP = :（不 strip）+ OPTFLAG ?= -O0
#     （deb 名带 "+debug" 后缀就是这个状态的外部指纹，之前一直没在意。）
#
# 代价（实机反汇编，arm64e slice）：didMoveToWindow 的 hook 体 665 条指令 / 96 次栈往返，
# didAddSubview: 判定链 92+107+62 = 261 条 —— 本该是几十条的量级。
#
# 所以三件事一起做（都必须写在 include common.mk 之前，那边是 ?=）：
#   1) DEBUG=0   —— 不进 DEBUG schema，{-DDEBUG -O0} 不再追加
#   2) STRIP=0   —— 把 SHOULD_STRIP 按到 false 那一支：不 strip（崩溃栈仍能符号化、
#                   `[Overlay] in-page?` 探针日志仍可读，取证能力不为了体积让步）
#   3) OPTFLAG   —— 覆盖它那一支的默认 -O0
# 已确认 Tweak.xm 里没有 `#ifdef DEBUG`，去掉 -DDEBUG 不会改行为。
DEBUG = 0
STRIP = 0
OPTFLAG = -O2

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := ColorfulCloudsNoAds

ColorfulCloudsNoAds_FILES := Tweak.xm
ColorfulCloudsNoAds_CFLAGS := -fobjc-arc -w
ColorfulCloudsNoAds_FRAMEWORKS := UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
