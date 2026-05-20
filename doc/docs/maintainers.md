# Maintainers

There are various responsibilities and processes maintainers need to do to update Terrain3D.

1. Ensure PR builds are successful, and occasionally make changes to the build scripts when Github makes changes.
2. Ensure PRs are up to code standards and include XML documentation. You may need to generate the XML for them first.
3. [Update docs](#using-the-documentation-generation-tools) to generate the XML and RST files. Readthedocs will update automatically once PRs are merged. Though if it fails, you may need to log in and figure out why. It can be a bit finicky. They have automatic tags.
4. [Update C# bindings](generating_csharp_bindings.md) as the API changes.
5. Update versions and tags as indicated below.


## Updating New Versions and Releases of Terrain3D

Edit the following files on new releases and versions.

### New Terrain3D Release Version
* Set src/terrain_3d.h : _version
* Set project/addons/terrain_3d/plugin.cfg : version
* Set doc/conf.py : version
* Rebuild the docs with doc/build_docs.sh
* Review minimum version in terrain.gdextension
* Create a new tag for github
* Create a new branch for new milestones (1.0) so readthedocs will create a new version. You may need to enable it on their website.
* Reassign the `stable` tag for readthedocs to update that doc build. `latest` automatically builds off of `main`. Confirm that it correctly builds, as sometimes it doesn't.


### New Terrain3DRegion Data Format Version
* Update src/terrain_3d_data.h : CURRENT_DATA_VERSION
* Update docs/data_format.md


### New Year:
* Update Copyright header in all source files and conf.py


## Maintaining multiple versions

Occasionally we might maintain two builds of the same version, such as `1.1-godot4.4` and `1.1` for Godot 4.5+. In this case the difference was the former used the godot-cpp 4.4 API, the latter used the 4.5 API. There was a minor but important difference in our code. I wanted all commits from one branch to be in the other branch, except for the few that changed the godot-cpp API. Here's how that process worked.

1. At the time, `main` was 1.1-dev and I had made a separate `1.1-godot4.4` branch. I made a commit changing godot-cpp to the 4.5 API.
2. Then after some commits, I cherry-picked all of the new ones from `main` into `1.1-godot4.4`.
3. On `main`, I created a tag called `_last-cherry-pick` so that when I periodically updated the 4.4 branch I knew where I left off.
4. Bulk cherry-picking is easy to do with the following:

```
git checkout 1.1-godot4.4                              # Start in the destination branch
git cherry-pick --no-merges _last-cherry-pick..main    # Use any two hashes or tags
git diff main                                          # Ensure the only difference is the 4.5 API change in this example
git push                                               # Upload all bulk cherry-picked commits
```


