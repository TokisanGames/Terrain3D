import os
import sys
import shutil

src_dir = 'clang-hooks'
dist_dir = '.git/hooks'

if not os.path.exists(dist_dir):
    print("Error: this directory is not a git repository!")
    sys.exit(0)

for file in os.listdir(src_dir):
    shutil.copy(os.path.join(src_dir, file), dist_dir)