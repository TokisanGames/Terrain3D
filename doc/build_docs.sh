#!/bin/bash
GODOT=/c/gd/bin/Godot_v4.4.1-stable_win64.exe
MAKERST=/c/gd/godot/doc/tools/make_rst.py
REPO=`git rev-parse --show-toplevel`

pushd $REPO

echo --- Running Godot to dump XML files
cd $REPO/project
$GODOT --doctool ../doc --gdextension-docs

cd $REPO/doc

echo --- Running make_rst.py to produce sphinx output
$MAKERST --verbose --filter Terrain3D --output api path doc_classes/ 2>&1 | egrep -v 'Unresolved (type|enum)'

echo --- Generating html
make clean
make html 2>&1 | grep -Pv 'WARNING: undefined label: (?!'\''class_terrain3d)' | egrep -v '(local id not found|copying images|writing output|reading sources|toctree contains reference .+api/class_variant)'

start _build/html/index.html
popd
