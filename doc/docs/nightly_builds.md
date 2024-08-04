Nightly Builds
====================

Traditionally, across countless dev projects, nightly builds are automatically built from the main development tree every night. 

Our Github repository is configured to build automatically on every commit and PR push. If you want to test more recent versions of Terrain3D than the releases, you can download these "push builds" or "nightly builds". 

They are exactly the same construction as the releases except for the commit used. However, they are inherently less tested as new commits have more recently been merged in, and may have more problems than the release builds.

1. [Click here](https://github.com/TokisanGames/Terrain3D/actions/workflows/build.yml?query=branch%3Amain) for `Github Actions`, `Build All` workflow, `main` branch.

2. Click the most recent successful build:

```{image} images/build_workflow.png
:target: ../_images/build_workflow.png
```

3. Download the artifact, which is just a zip file with a "nightly" build. You must be logged in to github to download it.

```{image} images/build_artifact.png
:target: ../_images/build_artifact.png
```

If have trouble with the unsigned macOS released builds or wish to contribute, learn how to [Build from Source](building_from_source.md) on your own system.


## PR Builds

You can also test builds of PRs. Instead of specifying the `main` branch above, select the branch listed at the top of the PR. Or click the `Checks` tab, then `Build All` to see the summary page, which has the artifact.

If looking at a PR from another contributor, you'll need to look at their repository. Click the `from` branch at the top of the PR to go to their repo. Then click `Actions` to get the latest build from the appropriate branch.