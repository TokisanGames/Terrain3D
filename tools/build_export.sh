#!/usr/bin/bash

if [ "$1" == "" ]; then
	echo "Usage: $0 <version> <godot version>"
	echo "e.g. $0 0.8.1-alpha 4.1.1"
	exit 1
fi

NAME=terrain3d
VERSION=$1
GDVER=$2
FILE="../${NAME}_${VERSION}_gd${GDVER}"
BIN="addons/terrain_3d/bin"
INCLUDE="addons/terrain_3d demo project.godot"
EXCLUDE="$BIN/*.lib $BIN/*.exp"
WIN_DBG_FILE="$BIN/libterrain.windows.debug.x86_64.dll"
WIN_REL_FILE="$BIN/libterrain.windows.release.x86_64.dll"
LIN_DBG_FILE="$BIN/libterrain.linux.debug.x86_64.so"
LIN_REL_FILE="$BIN/libterrain.linux.release.x86_64.so"

if [ ! -e "project/$BIN" ]; then
	echo Bin dir not found. May not be in git root.
	exit 1
fi
pushd project > /dev/null

# Build Windows
if [ ! -e $WIN_DBG_FILE ] || [ ! -e $WIN_REL_FILE ]; then 
	scons platform=windows && scons platform=windows target=template_release
	strip $WIN_REL_FILE
	if [ $? -gt 0 ]; then
		echo Problem building. Exiting packaging script.
		exit $?
	fi
fi
zip -r ${FILE}_win64.zip $INCLUDE -x $EXCLUDE $LIN_DBG_FILE $LIN_REL_FILE

# Build linux
if [ ! -e $LIN_DBG_FILE ] || [ ! -e $LIN_REL_FILE ]; then 
	scons platform=linux && scons platform=linux target=template_release
	strip $LIN_REL_FILE
	if [ $? -gt 0 ]; then
		echo Problem building. Exiting packaging script.
		exit $?
	fi
fi
zip -r ${FILE}_linux.x86-64.zip $INCLUDE -x $EXCLUDE $WIN_DBG_FILE $WIN_REL_FILE

popd > /dev/null
