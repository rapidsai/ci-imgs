# SPDX-FileCopyrightText: Copyright (c) 2023-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

def compute_arch($x):
  $x + {ARCHES: ["amd64", "arm64"]};
  $x + {ARCHES: ["amd64"]};

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
  (if $x.IMAGE_REPO == "miniforge-cuda"
   then "-base-" else "-" end) as $base_id |
  "rapidsai/" + $repo + ":" + $tag_prefix + "cuda" + $x.CUDA_VER + $base_id + $x.LINUX_VER + "-" + "py" + $x.PYTHON_VER |
  $x + {IMAGE_NAME: .};

# Similar to compute_image_name(), but without RAPIDS version number
def compute_image_name_no_rapids_version($x):
  compute_repo($x) as $repo |
  compute_tag_prefix_no_rapids_version($x) as $tag_prefix |
  (if $x.IMAGE_REPO == "miniforge-cuda"
   then "-base-" else "-" end) as $base_id |
  "rapidsai/" + $repo + ":" + $tag_prefix + "cuda" + $x.CUDA_VER + $base_id + $x.LINUX_VER + "-" + "py" + $x.PYTHON_VER |
  $x + {IMAGE_NAME_NO_RAPIDS_VERSION: .};

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
    compute_image_name_no_rapids_version(.)
  ] |
  {include: .};
