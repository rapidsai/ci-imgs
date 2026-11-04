# SPDX-FileCopyrightText: Copyright (c) 2023-2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

def compute_arch($x):
  $x + {ARCHES: ["amd64", "arm64"]};

def compute_repo($x):
  if
    env.BUILD_TYPE == "pull-request"
  then
    "staging"
  else
    $x.IMAGE_REPO
  end;

def compute_tag_prefix($x):
  if
    env.BUILD_TYPE == "branch"
  then
    env.RAPIDS_VERSION_MAJOR_MINOR + "-"
  else
    $x.IMAGE_REPO + "-" + env.PR_NUM + "-" + env.RAPIDS_VERSION_MAJOR_MINOR + "-"
  end;

def compute_tag_prefix_no_rapids_version($x):
  if
    env.BUILD_TYPE == "branch"
  then
    ""
  else
    $x.IMAGE_REPO + "-" + env.PR_NUM + "-"
  end;

# Compute image URI in the form '{repo}/{name}:{tag}'
def compute_image_name($x):
  compute_repo($x) as $repo |
  compute_tag_prefix($x) as $tag_prefix |
  "rapidsai/" + $repo + ":" + $tag_prefix + "cuda" + $x.CUDA_VER + "-" + $x.LINUX_VER + "-" + "py" + $x.PYTHON_VER |
  $x + {IMAGE_NAME: .};

# Similar to compute_image_name(), but without RAPIDS version number
def compute_image_name_no_rapids_version($x):
  compute_repo($x) as $repo |
  compute_tag_prefix_no_rapids_version($x) as $tag_prefix |
  "rapidsai/" + $repo + ":" + $tag_prefix + "cuda" + $x.CUDA_VER + "-" + $x.LINUX_VER + "-" + "py" + $x.PYTHON_VER |
  $x + {IMAGE_NAME_NO_RAPIDS_VERSION: .};

# All builds can read the shared main-publication cache.
def compute_cache_image_name($x):
  "rapidsai/" + $x.IMAGE_REPO + ":cuda" + $x.CUDA_VER + "-" + $x.LINUX_VER + "-" + "py" + $x.PYTHON_VER |
  $x + {MAIN_CACHE_IMAGE_NAME: .};

# Main publications, including manual ones, refresh the shared cache. Every
# other ref writes only its own staging cache, including mirrored PR refs.
def compute_cache_write_image_name($x):
  if env.BUILD_TYPE == "branch" and env.GITHUB_REF == "refs/heads/main" then
    $x.MAIN_CACHE_IMAGE_NAME
  elif ((env.CACHE_REF_HASH // "") | test("^[0-9a-f]{32}$")) then
    "rapidsai/staging:" + $x.IMAGE_REPO + "-ref-" + env.CACHE_REF_HASH + "-cuda" + $x.CUDA_VER + "-" + $x.LINUX_VER + "-py" + $x.PYTHON_VER
  else
    error("CACHE_REF_HASH must identify the repository and full ref")
  end |
  $x + {CACHE_WRITE_IMAGE_NAME: .};

# Checks the current entry to see if it matches the given exclude
def matches($entry; $exclude):
  all($exclude | to_entries | .[]; $entry[.key] == .value);

# Checks the current entry to see if it matches any of the excludes.
# If so, produce no output. Otherwise, output the entry.
def filter_excludes($entry; $excludes):
  select(any($excludes[]; matches($entry; .)) | not);

def lists2dict($keys; $values):
  reduce range($keys | length) as $ind ({}; . + {($keys[$ind]): $values[$ind]});

def compute_matrix($input):
  ($input.exclude // []) as $excludes |
  $input | del(.exclude) |
  keys_unsorted as $matrix_keys |
  to_entries |
  map(.value) |
  [
    combinations |
    lists2dict($matrix_keys; .) |
    .IMAGE_REPO = .CI_IMAGE_CONFIG.IMAGE_REPO |
    .DOCKERFILE = .CI_IMAGE_CONFIG.dockerfile |
    .DOCKER_TARGET = .CI_IMAGE_CONFIG.docker_target |
    del(.CI_IMAGE_CONFIG) |
    filter_excludes(.; $excludes) |
    compute_arch(.) |
    compute_image_name(.) |
    compute_image_name_no_rapids_version(.) |
    compute_cache_image_name(.) |
    compute_cache_write_image_name(.)
  ] |
  {include: .};
