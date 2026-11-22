export THEOS_PACKAGE_SCHEME = rootless
# The game process is a plain arm64 app even on A12+ devices, so the arm64 slice is the one that loads;
# arm64e is built too for processes that do run arm64e.
ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:16.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ProjetoGrau2Cash
ProjetoGrau2Cash_FILES = Tweak.mm
ProjetoGrau2Cash_CCFLAGS = -std=c++20
ProjetoGrau2Cash_CFLAGS = -fobjc-arc -Wall -Wextra

include $(THEOS_MAKE_PATH)/tweak.mk
