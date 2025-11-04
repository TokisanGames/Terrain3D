import os
import stat
import sys
import shutil

src_dir = 'tools/hooks'
dist_dir = '.git/hooks'

if not os.path.exists(dist_dir):
    print("Error: this directory is not a git repository!")
    sys.exit(1)

for file in os.listdir(src_dir):
    shutil.copy(os.path.join(src_dir, file), dist_dir)

# Unix user needs the execute bit set.
if os.name == "posix":
    mode = stat.S_IRWXU | stat.S_IRGRP | stat.S_IROTH;
    os.chmod(os.path.join(dist_dir, "pre-commit"), mode);
    os.chmod(os.path.join(dist_dir, "pre-commit-clang-format"), mode);

print("Copied tools/hooks/* to .git/hooks")
