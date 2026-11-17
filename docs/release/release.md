---
title: Document For Releasing
description: This Document outlines how issue a new Release.
tags: [deploy]
mdsh:
  terminal:
    cols: 160
  shell: zsh
  show_stderr: true
author: Gautam Dey<gautam.dey77@gmail.com>
---
# release

## Setup; make sure in the directory

```zsh {#change_to_root_dir skip links}
REPODIR="$MDSH_DIR/../../"
echo "REPO_DIR: $REPODIR"
cd $REPODIR
pwd
```

```zsh {#git_fetch_main depends=change_to_root_dir collapse-output}
git fetch --prune --all
git switch main
git pull --ff-only
```

### Tag version and push 

```textbox {#version_string var=VersionString}
0.6.0
```

```zsh {#git_tag depends=git_fetch_main}
git tag v${MDSH_VAR_VersionString} && git push origin v${MDSH_VAR_VersionString}
```


# Now wait till CI is done building the assets.

After witch go to the [godot engine asset store](https://store.godotengine.org/asset/gdey/godotnvim/)'s page for the plugin, and use the information from [store/assets-store.md](../store/asset-store.md) to fill in the page.

You should be able to get the [zip here](https://github.com/gdey/godotnvim/releases/tag/{{$MDSH_VAR_VersionString:"0.6.0"}}):
https://github.com/gdey/godotnvim/releases/download/v{{$MDSH_VAR_VersionString:"0.6.0"}}/godot_nvim-{{$MDSH_VAR_VersionString:"0.6.0"}}.zip
