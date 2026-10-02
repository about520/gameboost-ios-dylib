#
# Makefile —— 可选：给用 Theos 的人
#
# 说明：本工程**不需要 Theos**。主推路径是 build_dylib.sh（直接调 xcrun clang），
#      因为我们要的是一个裸 dylib 用来注入 IPA，而不是 .deb 包。
#
# 如果你习惯用 Theos 管理工程：
#   make clean && make
# 产物在 .theos/obj/ 下。
#
# 注意：本工程刻意**不依赖 CydiaSubstrate / libhooker / ellekit**，
#      所有 hook 都是手写 method_setImplementation，所以不用链 substrate，
#      也就能在免越狱环境里 load 成功。
#

ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = GameBoost

GameBoost_FILES = $(wildcard Sources/*.m)
GameBoost_CFLAGS = -fobjc-arc -fmodules -O2
GameBoost_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics
GameBoost_LDFLAGS = -Wl,-install_name,@executable_path/Frameworks/GameBoost.dylib

include $(THEOS_MAKE_PATH)/library.mk
